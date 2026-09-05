// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IJobFunds, OrgJobBalance, JobLock} from "../../src/interfaces/IJobFunds.sol";
import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";
import {JobFunds} from "../../src/JobFunds.sol";
import {Errors} from "../../src/Errors.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {USDC} from "../mocks/USDC.sol";

import {OrgTestBase, TestCommitmentRegistration} from "../shared/OrgTestBase.sol";

contract CommitmentWithoutRegistration {}

contract ContractTreasury {
    function approveToken(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function depositJobFunds(IJobFunds jobFunds, uint256 orgId, uint256 amount) external {
        jobFunds.deposit(orgId, amount);
    }
}

contract JobFundsIntegrationTest is OrgTestBase {
    bytes32 private constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint256 orgId;

    function test_constructor_revert_zeroStakeToken() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new JobFunds(
            IERC20(address(0)), IOrgRegistry(address(registry)), feeRecipient, contractOwner, address(forwarder)
        );
    }

    function test_constructor_revert_zeroOrgRegistry() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new JobFunds(IERC20(address(usdc)), IOrgRegistry(address(0)), feeRecipient, contractOwner, address(forwarder));
    }

    function test_constructor_revert_zeroFeeRecipient() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new JobFunds(
            IERC20(address(usdc)), IOrgRegistry(address(registry)), address(0), contractOwner, address(forwarder)
        );
    }

    function test_constructor_revert_zeroOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new JobFunds(
            IERC20(address(usdc)), IOrgRegistry(address(registry)), feeRecipient, address(0), address(forwarder)
        );
    }

    function test_constructor_revert_selfFeeRecipient() public {
        address predictedJobFunds = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidFeeRecipient.selector, predictedJobFunds));
        new JobFunds(
            IERC20(address(usdc)), IOrgRegistry(address(registry)), predictedJobFunds, contractOwner, address(forwarder)
        );
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.RenounceDisabled.selector);
        jobFunds.renounceOwnership();

        assertEq(jobFunds.owner(), contractOwner);
    }

    function test_pause_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        jobFunds.pause();
    }

    function test_ownerCanPauseAndUnpause() public {
        vm.startPrank(contractOwner);
        jobFunds.pause();
        assertTrue(jobFunds.paused());

        jobFunds.unpause();
        vm.stopPrank();

        assertFalse(jobFunds.paused());
    }

    function test_unpause_revert_notOwner() public {
        vm.prank(contractOwner);
        jobFunds.pause();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        jobFunds.unpause();
    }

    function test_transferOwnership_twoStepTransfersOwnerAuthority() public {
        address newOwner = makeAddr("newJobFundsOwner");

        vm.prank(contractOwner);
        jobFunds.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", newOwner));
        jobFunds.pause();

        vm.prank(newOwner);
        jobFunds.acceptOwnership();

        vm.prank(newOwner);
        jobFunds.pause();

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", contractOwner));
        jobFunds.unpause();

        vm.prank(newOwner);
        jobFunds.unpause();

        assertEq(jobFunds.owner(), newOwner);
        assertFalse(jobFunds.paused());
    }

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "test.com");

        vm.startPrank(contractOwner);
        jobFunds.registerJobCommitment(address(this), 1);
        jobFunds.setCurrentJobCommitment(address(this));
        vm.stopPrank();

        _fundAndDeposit(orgId, orgOwner1, 10_000_000_000);
    }

    function test_publishJob() public {
        uint256 stakeAmount = 500_000_000;
        uint256 feeAmount = 10_000_000;
        uint256 jobId = 1;

        uint256 jobFundsBalBefore = usdc.balanceOf(address(jobFunds));
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);

        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, feeAmount), jobId);

        assertEq(usdc.balanceOf(address(jobFunds)), jobFundsBalBefore - feeAmount);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalBefore + feeAmount);

        OrgJobBalance memory balance = jobFunds.jobBalance(orgId);
        assertEq(balance.available, 10_000_000_000 - feeAmount - stakeAmount);
        assertEq(balance.stakedInJobs, stakeAmount);
        assertEq(jobFunds.availableBalance(orgId), 10_000_000_000 - feeAmount - stakeAmount);
    }

    function test_publishJob_emitsEvent() public {
        uint256 jobId = 1;
        uint256 stakeAmount = 500_000_000;
        uint256 feeAmount = 10_000_000;

        vm.expectEmit(true, true, true, true);
        emit IJobFunds.JobFunded(address(this), orgId, jobId, orgOwner1, stakeAmount, feeAmount);
        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, feeAmount), jobId);
    }

    function test_publishJob_revert_unknownCommitment() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.JobCommitmentNotRegistered.selector, stranger));
        _publishTestJob(stranger, orgId, stranger, 100, 0);
    }

    function test_registeredCommitmentCannotDebitOrgFundsDirectly() public {
        address maliciousCommitment = _deployTestCommitment();
        uint256 availableBefore = jobFunds.availableBalance(orgId);
        uint256 recipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.prank(contractOwner);
        jobFunds.registerJobCommitment(maliciousCommitment, 1);

        vm.prank(maliciousCommitment);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.JobCommitmentNotCurrent.selector, maliciousCommitment, address(this))
        );
        jobFunds.publishJob(maliciousCommitment, orgId, 1, availableBefore - 1, feeRecipient, bytes(""));

        assertEq(jobFunds.availableBalance(orgId), availableBefore);
        assertEq(usdc.balanceOf(feeRecipient), recipientBalanceBefore);
    }

    function test_publishJob_revert_creatorNotJobManager() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobManager.selector, orgId, stranger));
        _publishTestJob(address(this), orgId, stranger, 100, 0);
    }

    function test_publishJob_revert_whenPaused() public {
        vm.prank(contractOwner);
        jobFunds.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _publishTestJob(address(this), orgId, orgOwner1, 500_000_000, 10_000_000);
    }

    function test_depositWithAuthorization_revert_wrongOrgTreasury() public {
        uint256 amount = 1_000_000;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, stranger));
        jobFunds.depositWithAuthorization(orgId, amount, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_depositWithAuthorization_revert_zeroAmount() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        jobFunds.depositWithAuthorization(orgId, 0, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_depositWithAuthorization_revert_whenPaused() public {
        uint256 amount = 1_000_000;

        vm.prank(contractOwner);
        jobFunds.pause();

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        jobFunds.depositWithAuthorization(orgId, amount, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_depositWithAuthorization() public {
        uint256 treasuryPrivateKey = 0xBEEF;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "authorization.test");
        uint256 amount = 125_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("job-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceiveWithAuthorization(treasuryPrivateKey, treasury, amount, validAfter, validBefore, nonce);

        usdc.mint(treasury, amount);

        vm.startPrank(treasury);
        vm.expectEmit(true, true, false, true);
        emit IJobFunds.JobFundsDeposited(authorizationOrgId, treasury, amount);
        jobFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();

        assertEq(usdc.allowance(treasury, address(jobFunds)), 0);
        assertEq(usdc.balanceOf(address(jobFunds)), 10_000_000_000 + amount);
        assertEq(jobFunds.availableBalance(authorizationOrgId), amount);
        assertTrue(usdc.authorizationState(treasury, nonce));
    }

    function test_depositWithAuthorization_revert_replayedAuthorization() public {
        uint256 treasuryPrivateKey = 0xCAFE;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "replay.test");
        uint256 amount = 1_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("replayed-job-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceiveWithAuthorization(treasuryPrivateKey, treasury, amount, validAfter, validBefore, nonce);

        usdc.mint(treasury, amount);

        vm.startPrank(treasury);
        jobFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);
        vm.expectRevert(MockUSDC.AuthorizationAlreadyUsed.selector);
        jobFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();
    }

    function test_depositWithAuthorization_revert_expiredAuthorization() public {
        uint256 treasuryPrivateKey = 0xD00D;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "expired.test");
        uint256 amount = 1_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 minutes;
        bytes32 nonce = keccak256("expired-job-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceiveWithAuthorization(treasuryPrivateKey, treasury, amount, validAfter, validBefore, nonce);

        usdc.mint(treasury, amount);
        vm.warp(validBefore);

        vm.prank(treasury);
        vm.expectRevert(MockUSDC.AuthorizationExpired.selector);
        jobFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);
    }

    function test_depositWithAuthorization_atValidAfter_preservesStateAndAllowsRetry() public {
        uint256 treasuryPrivateKey = 0xBEEF;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "not-yet-valid.test");
        uint256 amount = 125_000_000;
        uint256 validAfter = block.timestamp + 1 minutes;
        uint256 validBefore = validAfter + 1 hours;
        bytes32 nonce = keccak256("not-yet-valid-job-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceiveWithAuthorization(treasuryPrivateKey, treasury, amount, validAfter, validBefore, nonce);
        uint256 tokenBalanceBefore = usdc.balanceOf(address(jobFunds));
        uint256 accountedBefore = jobFunds.totalAccountedBalance();

        usdc.mint(treasury, amount);
        vm.warp(validAfter);

        vm.prank(treasury);
        vm.expectRevert(MockUSDC.AuthorizationNotYetValid.selector);
        jobFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), amount);
        assertEq(usdc.balanceOf(address(jobFunds)), tokenBalanceBefore);
        assertEq(jobFunds.availableBalance(authorizationOrgId), 0);
        assertEq(jobFunds.totalAccountedBalance(), accountedBefore);
        assertFalse(usdc.authorizationState(treasury, nonce));

        vm.warp(validAfter + 1);
        vm.prank(treasury);
        jobFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(jobFunds)), tokenBalanceBefore + amount);
        assertEq(jobFunds.availableBalance(authorizationOrgId), amount);
        assertEq(jobFunds.totalAccountedBalance(), accountedBefore + amount);
        assertTrue(usdc.authorizationState(treasury, nonce));
    }

    function test_depositWithAuthorization_wrongAmount_preservesStateAndAllowsRetry() public {
        uint256 treasuryPrivateKey = 0xBEEF;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "wrong-amount.test");
        uint256 amount = 125_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("wrong-amount-job-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceiveWithAuthorization(treasuryPrivateKey, treasury, amount, validAfter, validBefore, nonce);
        uint256 tokenBalanceBefore = usdc.balanceOf(address(jobFunds));
        uint256 accountedBefore = jobFunds.totalAccountedBalance();

        usdc.mint(treasury, amount + 1);

        vm.prank(treasury);
        vm.expectRevert(MockUSDC.InvalidAuthorizationSigner.selector);
        jobFunds.depositWithAuthorization(authorizationOrgId, amount + 1, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), amount + 1);
        assertEq(usdc.balanceOf(address(jobFunds)), tokenBalanceBefore);
        assertEq(jobFunds.availableBalance(authorizationOrgId), 0);
        assertEq(jobFunds.totalAccountedBalance(), accountedBefore);
        assertFalse(usdc.authorizationState(treasury, nonce));

        vm.prank(treasury);
        jobFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), 1);
        assertEq(usdc.balanceOf(address(jobFunds)), tokenBalanceBefore + amount);
        assertEq(jobFunds.availableBalance(authorizationOrgId), amount);
        assertEq(jobFunds.totalAccountedBalance(), accountedBefore + amount);
        assertTrue(usdc.authorizationState(treasury, nonce));
    }

    function test_depositWithAuthorization_insufficientTokens_preservesStateAndAllowsRetry() public {
        uint256 treasuryPrivateKey = 0xBEEF;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "insufficient-tokens.test");
        uint256 amount = 125_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("insufficient-tokens-job-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceiveWithAuthorization(treasuryPrivateKey, treasury, amount, validAfter, validBefore, nonce);
        uint256 tokenBalanceBefore = usdc.balanceOf(address(jobFunds));
        uint256 accountedBefore = jobFunds.totalAccountedBalance();

        usdc.mint(treasury, amount - 1);

        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, treasury, amount - 1, amount)
        );
        jobFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), amount - 1);
        assertEq(usdc.balanceOf(address(jobFunds)), tokenBalanceBefore);
        assertEq(jobFunds.availableBalance(authorizationOrgId), 0);
        assertEq(jobFunds.totalAccountedBalance(), accountedBefore);
        assertFalse(usdc.authorizationState(treasury, nonce));

        usdc.mint(treasury, 1);
        vm.prank(treasury);
        jobFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(jobFunds)), tokenBalanceBefore + amount);
        assertEq(jobFunds.availableBalance(authorizationOrgId), amount);
        assertEq(jobFunds.totalAccountedBalance(), accountedBefore + amount);
        assertTrue(usdc.authorizationState(treasury, nonce));
    }

    function test_deposit_fromContractTreasury() public {
        ContractTreasury treasury = new ContractTreasury();
        uint256 contractTreasuryOrgId = _createOrg(address(treasury), "contract-treasury.test");
        uint256 amount = 125_000_000;
        uint256 jobFundsBalanceBefore = usdc.balanceOf(address(jobFunds));
        uint256 totalAccountedBefore = jobFunds.totalAccountedBalance();

        usdc.mint(address(treasury), amount);
        treasury.approveToken(usdc, address(jobFunds), amount);

        vm.expectEmit(true, true, false, true);
        emit IJobFunds.JobFundsDeposited(contractTreasuryOrgId, address(treasury), amount);
        treasury.depositJobFunds(jobFunds, contractTreasuryOrgId, amount);

        assertEq(usdc.allowance(address(treasury), address(jobFunds)), 0);
        assertEq(usdc.balanceOf(address(jobFunds)), jobFundsBalanceBefore + amount);
        assertEq(jobFunds.availableBalance(contractTreasuryOrgId), amount);
        assertEq(jobFunds.totalAccountedBalance(), totalAccountedBefore + amount);
    }

    function test_deposit_revert_wrongOrgTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, stranger));
        jobFunds.deposit(orgId, 1_000_000);
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        jobFunds.deposit(orgId, 0);
    }

    function test_deposit_revert_whenPaused() public {
        vm.prank(contractOwner);
        jobFunds.pause();

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        jobFunds.deposit(orgId, 1_000_000);
    }

    function test_withdraw() public {
        uint256 withdrawAmount = 5_000_000_000;
        uint256 ownerBalanceBefore = usdc.balanceOf(orgOwner1);

        vm.prank(orgOwner1);
        jobFunds.withdraw(orgId, withdrawAmount);

        assertEq(usdc.balanceOf(orgOwner1), ownerBalanceBefore + withdrawAmount);
        assertEq(jobFunds.availableBalance(orgId), 10_000_000_000 - withdrawAmount);
    }

    function test_withdraw_revert_insufficientAvailable() public {
        uint256 stakeAmount = 6_000_000_000;
        _publishTestJob(address(this), orgId, orgOwner1, stakeAmount, 0);

        uint256 available = 10_000_000_000 - stakeAmount;

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, available + 1, available));
        jobFunds.withdraw(orgId, available + 1);
    }

    function test_withdraw_revert_wrongOrgTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, stranger));
        jobFunds.withdraw(orgId, 1);
    }

    function test_setFeeRecipient_updatesFeeDestination() public {
        address newRecipient = makeAddr("newRecipient");
        uint256 feeAmount = 10_000_000;

        vm.prank(contractOwner);
        jobFunds.setFeeRecipient(newRecipient);
        feeRecipient = newRecipient;

        _publishTestJob(address(this), orgId, orgOwner1, 500_000_000, feeAmount);

        assertEq(usdc.balanceOf(newRecipient), feeAmount);
    }

    function test_setFeeRecipient_emitsEvent() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(contractOwner);
        vm.expectEmit(true, true, false, true);
        emit IJobFunds.FeeRecipientUpdated(feeRecipient, newRecipient);
        jobFunds.setFeeRecipient(newRecipient);
    }

    function test_setFeeRecipient_revert_zeroAddress() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        jobFunds.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_revert_notOwner() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        jobFunds.setFeeRecipient(newRecipient);
    }

    function test_setFeeRecipient_revert_selfAddress() public {
        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidFeeRecipient.selector, address(jobFunds)));
        jobFunds.setFeeRecipient(address(jobFunds));
    }

    function test_publishJob_revert_registeredNonCurrentCommitment() public {
        address oldCommitment = _deployTestCommitment();

        vm.prank(contractOwner);
        jobFunds.registerJobCommitment(oldCommitment, 1);

        vm.expectRevert(abi.encodeWithSelector(Errors.JobCommitmentNotCurrent.selector, oldCommitment, address(this)));
        _publishTestJob(oldCommitment, orgId, orgOwner1, 100, 0);
    }

    function test_nonCurrentCommitment_settlesExistingLock() public {
        address oldCommitment = _deployTestCommitment();
        uint256 jobId = 1;
        uint256 stakeAmount = 500_000_000;

        vm.startPrank(contractOwner);
        jobFunds.registerJobCommitment(oldCommitment, 1);
        jobFunds.setCurrentJobCommitment(oldCommitment);
        vm.stopPrank();

        assertEq(_publishTestJob(oldCommitment, orgId, orgOwner1, stakeAmount, 0), jobId);

        vm.prank(contractOwner);
        jobFunds.setCurrentJobCommitment(address(this));

        vm.expectRevert(abi.encodeWithSelector(Errors.JobCommitmentNotCurrent.selector, oldCommitment, address(this)));
        _publishTestJob(oldCommitment, orgId, orgOwner1, stakeAmount, 0);

        vm.prank(oldCommitment);
        jobFunds.settleJob(orgId, jobId, stakeAmount);

        JobLock memory lock = jobFunds.jobLock(oldCommitment, jobId);
        assertEq(lock.stakeAmount, 0);
    }

    function test_publishJob_revert_insufficientBalance() public {
        uint256 available = 10_000_000_000;
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, available + 1, available));
        _publishTestJob(address(this), orgId, orgOwner1, available + 1, 0);
    }

    function test_publishJob_revert_orgNotFound() public {
        uint256 fakeOrgId = 999;

        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, fakeOrgId));
        _publishTestJob(address(this), fakeOrgId, orgOwner1, 100, 0);
    }

    function test_publishJob_revert_zeroStakeAmount() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        _publishTestJob(address(this), orgId, orgOwner1, 0, 10_000_000);
    }

    function test_settleJob_fullReturn() public {
        uint256 stakeAmount = 500_000_000;
        uint256 jobId = 1;
        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, 0), jobId);

        jobFunds.settleJob(orgId, jobId, stakeAmount);

        OrgJobBalance memory balance = jobFunds.jobBalance(orgId);
        assertEq(balance.stakedInJobs, 0);
        assertEq(balance.available, 10_000_000_000);
    }

    function test_settleJob_returnAmountEqualsLock_succeeds() public {
        uint256 stakeAmount = 500_000_000;
        uint256 jobId = 1;
        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, 0), jobId);

        jobFunds.settleJob(orgId, jobId, stakeAmount);

        JobLock memory lock = jobFunds.jobLock(address(this), jobId);
        assertEq(lock.stakeAmount, 0);
        assertEq(jobFunds.availableBalance(orgId), 10_000_000_000);
    }

    function test_settleJob_partialReturn() public {
        uint256 stakeAmount = 500_000_000;
        uint256 returnAmount = 400_000_000;
        uint256 slashedAmount = 100_000_000;
        uint256 jobId = 1;

        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, 0), jobId);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);
        jobFunds.settleJob(orgId, jobId, returnAmount);

        OrgJobBalance memory balance = jobFunds.jobBalance(orgId);
        assertEq(balance.stakedInJobs, 0);
        assertEq(balance.available, 10_000_000_000 - slashedAmount);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalBefore, slashedAmount, "Slash mismatch");
    }

    function test_settleJob_zeroReturn() public {
        uint256 stakeAmount = 500_000_000;
        uint256 jobId = 1;
        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, 0), jobId);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);
        jobFunds.settleJob(orgId, jobId, 0);

        OrgJobBalance memory balance = jobFunds.jobBalance(orgId);
        assertEq(balance.stakedInJobs, 0);
        assertEq(balance.available, 10_000_000_000 - stakeAmount);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalBefore, stakeAmount, "Slash mismatch");
    }

    function test_settleJob_emitsEvent() public {
        uint256 stakeAmount = 500_000_000;
        uint256 jobId = 1;
        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, 0), jobId);

        vm.expectEmit(true, true, true, true);
        emit IJobFunds.StakeBurned(address(this), orgId, jobId, 200_000_000);
        vm.expectEmit(true, true, true, true);
        emit IJobFunds.JobSettled(address(this), orgId, jobId, 300_000_000, 200_000_000);
        jobFunds.settleJob(orgId, jobId, 300_000_000);
    }

    function test_settleJob_revert_unknownCommitment() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobCommitmentNotRegistered.selector, stranger));
        jobFunds.settleJob(orgId, 1, 100);
    }

    function test_settleJob_revert_orgMismatch() public {
        uint256 secondOrgId = _createOrg(orgOwner2, "second.com");
        uint256 stakeAmount = 500_000_000;
        uint256 jobId = 1;

        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, 0), jobId);

        vm.expectRevert(abi.encodeWithSelector(Errors.JobLockOrgMismatch.selector, secondOrgId, orgId));
        jobFunds.settleJob(secondOrgId, jobId, stakeAmount);
    }

    function test_settleJob_allowedWhenPaused() public {
        uint256 stakeAmount = 500_000_000;
        uint256 jobId = 1;

        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, 0), jobId);

        vm.prank(contractOwner);
        jobFunds.pause();

        jobFunds.settleJob(orgId, jobId, stakeAmount);

        OrgJobBalance memory balance = jobFunds.jobBalance(orgId);
        assertEq(balance.stakedInJobs, 0);
    }

    function test_settleJob_revert_exceedsLockedAmount() public {
        uint256 stakeAmount = 500_000_000;
        uint256 jobId = 1;
        assertEq(_publishTestJob(address(this), orgId, orgOwner1, stakeAmount, 0), jobId);

        uint256 returnAmount = stakeAmount + 100_000_000;

        vm.expectRevert(abi.encodeWithSelector(Errors.ExceedsLockedAmount.selector, returnAmount, stakeAmount));
        jobFunds.settleJob(orgId, jobId, returnAmount);
    }

    function test_settleJob_revert_jobNotLocked() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.JobNotLocked.selector, address(this), 999));
        jobFunds.settleJob(orgId, 999, 0);
    }

    function test_publishJob_revert_jobAlreadyLocked() public {
        address repeatedIdCommitment = _deployTestCommitment();
        uint256 jobId = 1;

        vm.startPrank(contractOwner);
        jobFunds.registerJobCommitment(repeatedIdCommitment, 1);
        jobFunds.setCurrentJobCommitment(repeatedIdCommitment);
        vm.stopPrank();

        assertEq(_publishTestJob(repeatedIdCommitment, orgId, orgOwner1, 500_000_000, 0), jobId);

        vm.expectRevert(abi.encodeWithSelector(Errors.JobAlreadyLocked.selector, repeatedIdCommitment, jobId));
        _publishTestJob(repeatedIdCommitment, orgId, orgOwner1, 300_000_000, 0);
    }

    function test_registerJobCommitment_revert_duplicate() public {
        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobCommitmentAlreadyRegistered.selector, address(this)));
        jobFunds.registerJobCommitment(address(this), 1);
    }

    function test_registerJobCommitment_revert_notOwner() public {
        address newCommitment = _deployTestCommitment();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        jobFunds.registerJobCommitment(newCommitment, 1);
    }

    function test_registerJobCommitment_revert_missingRegistrationGetters() public {
        address badCommitment = address(new CommitmentWithoutRegistration());

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidJobCommitment.selector, badCommitment));
        jobFunds.registerJobCommitment(badCommitment, 1);
    }

    function test_registerJobCommitment_revert_wrongStakeToken() public {
        USDC wrongToken = new USDC();
        address badCommitment =
            address(new TestCommitmentRegistration(IERC20(address(wrongToken)), IJobFunds(address(jobFunds))));

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidJobCommitment.selector, badCommitment));
        jobFunds.registerJobCommitment(badCommitment, 1);
    }

    function test_registerJobCommitment_revert_wrongJobFunds() public {
        address badCommitment =
            address(new TestCommitmentRegistration(IERC20(address(usdc)), IJobFunds(makeAddr("wrongJobFunds"))));

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidJobCommitment.selector, badCommitment));
        jobFunds.registerJobCommitment(badCommitment, 1);
    }

    function test_setCurrentJobCommitment_revert_notFound() public {
        address unknownCommitment = _deployTestCommitment();

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobCommitmentNotRegistered.selector, unknownCommitment));
        jobFunds.setCurrentJobCommitment(unknownCommitment);
    }

    function test_setCurrentJobCommitment_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        jobFunds.setCurrentJobCommitment(address(this));
    }

    function test_setCurrentJobCommitment_revert_zeroAddress() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        jobFunds.setCurrentJobCommitment(address(0));
    }

    function test_registerJobCommitment_revert_eoaAddress() public {
        address notContract = makeAddr("notContract");

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ContractExpected.selector, notContract));
        jobFunds.registerJobCommitment(notContract, 1);
    }

    function test_sameJobIdFromDifferentCommitmentsUsesSeparateLocks() public {
        address secondCommitment = _deployTestCommitment();
        uint256 jobId = 1;
        uint256 firstStake = 500_000_000;
        uint256 secondStake = 300_000_000;

        vm.prank(contractOwner);
        jobFunds.registerJobCommitment(secondCommitment, 1);

        assertEq(_publishTestJob(address(this), orgId, orgOwner1, firstStake, 0), jobId);

        vm.prank(contractOwner);
        jobFunds.setCurrentJobCommitment(secondCommitment);

        assertEq(_publishTestJob(secondCommitment, orgId, orgOwner1, secondStake, 0), jobId);

        JobLock memory firstLock = jobFunds.jobLock(address(this), jobId);
        JobLock memory secondLock = jobFunds.jobLock(secondCommitment, jobId);

        assertEq(firstLock.orgId, orgId);
        assertEq(firstLock.stakeAmount, firstStake);
        assertEq(secondLock.orgId, orgId);
        assertEq(secondLock.stakeAmount, secondStake);

        jobFunds.settleJob(orgId, jobId, firstStake);

        firstLock = jobFunds.jobLock(address(this), jobId);
        secondLock = jobFunds.jobLock(secondCommitment, jobId);

        assertEq(firstLock.stakeAmount, 0);
        assertEq(secondLock.stakeAmount, secondStake);
    }

    function test_multipleJobs_lockAndRelease() public {
        uint256 job1Stake = 500_000_000;
        uint256 job2Stake = 300_000_000;
        uint256 jobId1 = 1;
        uint256 jobId2 = 2;

        assertEq(_publishTestJob(address(this), orgId, orgOwner1, job1Stake, 0), jobId1);
        assertEq(_publishTestJob(address(this), orgId, orgOwner1, job2Stake, 0), jobId2);

        OrgJobBalance memory balance = jobFunds.jobBalance(orgId);
        assertEq(balance.stakedInJobs, job1Stake + job2Stake);
        assertEq(balance.available, 10_000_000_000 - job1Stake - job2Stake);

        jobFunds.settleJob(orgId, jobId1, job1Stake);

        balance = jobFunds.jobBalance(orgId);
        assertEq(balance.stakedInJobs, job2Stake);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);
        jobFunds.settleJob(orgId, jobId2, 200_000_000);

        balance = jobFunds.jobBalance(orgId);
        assertEq(balance.stakedInJobs, 0);
        assertEq(balance.available, 10_000_000_000 - 100_000_000);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalBefore, 100_000_000, "Slash mismatch");
    }

    function test_rescueTokens_revert_notOwner() public {
        usdc.mint(address(jobFunds), 1_000_000);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        jobFunds.rescueTokens(address(usdc), stranger, 1);
    }

    function test_rescueTokens_revert_zeroRecipient() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        jobFunds.rescueTokens(address(usdc), address(0), 0);
    }

    function test_rescueTokens_otherToken_rescuesFullBalance() public {
        USDC otherToken = new USDC();
        uint256 amount = 1_000_000;
        address rescueTo = makeAddr("rescueRecipient");

        otherToken.mint(address(jobFunds), amount);

        vm.prank(contractOwner);
        jobFunds.rescueTokens(address(otherToken), rescueTo, amount);

        assertEq(otherToken.balanceOf(rescueTo), amount);
        assertEq(otherToken.balanceOf(address(jobFunds)), 0);
    }

    function test_rescueTokens_stakeToken_rescuesExactSurplus() public {
        uint256 surplus = 1_000_000;
        uint256 accounted = jobFunds.totalAccountedBalance();
        address rescueTo = makeAddr("rescueRecipient");

        usdc.mint(address(jobFunds), surplus);

        vm.prank(contractOwner);
        jobFunds.rescueTokens(address(usdc), rescueTo, surplus);

        assertEq(usdc.balanceOf(rescueTo), surplus);
        assertEq(usdc.balanceOf(address(jobFunds)), accounted);
        assertEq(jobFunds.totalAccountedBalance(), accounted);
    }

    function test_rescueTokens_stakeToken_revert_aboveSurplus() public {
        uint256 surplus = 1_000_000;
        uint256 requested = surplus + 1;

        usdc.mint(address(jobFunds), surplus);

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueExceedsSurplus.selector, requested, surplus));
        jobFunds.rescueTokens(address(usdc), makeAddr("rescueRecipient"), requested);
    }

    function _signReceiveWithAuthorization(
        uint256 signerPrivateKey,
        address from,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) private view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, address(jobFunds), value, validAfter, validBefore, nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));

        return vm.sign(signerPrivateKey, digest);
    }
}
