// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ICommitmentFunds, OrgCommitmentBalance, CommitmentLock} from "../../src/interfaces/ICommitmentFunds.sol";
import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";
import {CommitmentFunds} from "../../src/CommitmentFunds.sol";
import {Errors} from "../../src/Errors.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {USDC} from "../mocks/USDC.sol";

import {OrgTestBase, TestCommitmentRegistration} from "../shared/OrgTestBase.sol";

contract CommitmentWithoutRegistration {}

contract MutableCommitmentRegistration {
    uint32 public commitmentVersion;
    ICommitmentFunds public immutable commitmentFunds;

    constructor(ICommitmentFunds commitmentFunds_) {
        commitmentFunds = commitmentFunds_;
        commitmentVersion = 1;
    }

    function setCommitmentVersion(uint32 version) external {
        commitmentVersion = version;
    }
}

contract ContractTreasury {
    function approveToken(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function depositCommitmentFunds(ICommitmentFunds commitmentFunds, uint256 orgId, uint256 amount) external {
        commitmentFunds.deposit(orgId, amount);
    }
}

contract CommitmentFundsIntegrationTest is OrgTestBase {
    uint256 orgId;

    function test_constructor_revert_zeroStakeToken() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CommitmentFunds(
            IERC20(address(0)), IOrgRegistry(address(registry)), feeRecipient, contractOwner, address(forwarder)
        );
    }

    function test_constructor_revert_zeroOrgRegistry() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CommitmentFunds(
            IERC20(address(usdc)), IOrgRegistry(address(0)), feeRecipient, contractOwner, address(forwarder)
        );
    }

    function test_constructor_revert_zeroFeeRecipient() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CommitmentFunds(
            IERC20(address(usdc)), IOrgRegistry(address(registry)), address(0), contractOwner, address(forwarder)
        );
    }

    function test_constructor_revert_zeroOwner() public {
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new CommitmentFunds(
            IERC20(address(usdc)), IOrgRegistry(address(registry)), feeRecipient, address(0), address(forwarder)
        );
    }

    function test_constructor_revert_selfFeeRecipient() public {
        address predictedCommitmentFunds = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidFeeRecipient.selector, predictedCommitmentFunds));
        new CommitmentFunds(
            IERC20(address(usdc)),
            IOrgRegistry(address(registry)),
            predictedCommitmentFunds,
            contractOwner,
            address(forwarder)
        );
    }

    function test_renounceOwnership_reverts() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.RenounceDisabled.selector);
        commitmentFunds.renounceOwnership();

        assertEq(commitmentFunds.owner(), contractOwner);
    }

    function test_pause_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        commitmentFunds.pause();
    }

    function test_ownerCanPauseAndUnpause() public {
        vm.startPrank(contractOwner);
        commitmentFunds.pause();
        assertTrue(commitmentFunds.paused());

        commitmentFunds.unpause();
        vm.stopPrank();

        assertFalse(commitmentFunds.paused());
    }

    function test_unpause_revert_notOwner() public {
        vm.prank(contractOwner);
        commitmentFunds.pause();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        commitmentFunds.unpause();
    }

    function test_transferOwnership_twoStepTransfersOwnerAuthority() public {
        address newOwner = makeAddr("newCommitmentFundsOwner");

        vm.prank(contractOwner);
        commitmentFunds.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", newOwner));
        commitmentFunds.pause();

        vm.prank(newOwner);
        commitmentFunds.acceptOwnership();

        vm.prank(newOwner);
        commitmentFunds.pause();

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", contractOwner));
        commitmentFunds.unpause();

        vm.prank(newOwner);
        commitmentFunds.unpause();

        assertEq(commitmentFunds.owner(), newOwner);
        assertFalse(commitmentFunds.paused());
    }

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "test.com");

        vm.startPrank(contractOwner);
        commitmentFunds.registerResponseCommitment(address(this), 1);
        commitmentFunds.setCurrentResponseCommitment(address(this));
        vm.stopPrank();

        _fundAndDeposit(orgId, orgOwner1, 10_000_000_000);
    }

    function test_activateCommitment() public {
        uint256 stakeAmount = 500_000_000;
        uint256 feeAmount = 10_000_000;
        uint256 commitmentId = 1;

        uint256 commitmentFundsBalBefore = usdc.balanceOf(address(commitmentFunds));
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);

        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, feeAmount), commitmentId);

        assertEq(usdc.balanceOf(address(commitmentFunds)), commitmentFundsBalBefore - feeAmount);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalBefore + feeAmount);

        OrgCommitmentBalance memory balance = commitmentFunds.commitmentBalance(orgId);
        assertEq(balance.available, 10_000_000_000 - feeAmount - stakeAmount);
        assertEq(balance.lockedInCommitments, stakeAmount);
        assertEq(commitmentFunds.availableBalance(orgId), 10_000_000_000 - feeAmount - stakeAmount);
    }

    function test_activateCommitment_emitsEvent() public {
        uint256 commitmentId = 1;
        uint256 stakeAmount = 500_000_000;
        uint256 feeAmount = 10_000_000;

        vm.expectEmit(true, true, true, true);
        emit ICommitmentFunds.CommitmentStakeLocked(
            address(this), orgId, commitmentId, orgOwner1, stakeAmount, feeAmount
        );
        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, feeAmount), commitmentId);
    }

    function test_activateCommitment_revert_unknownCommitment() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ResponseCommitmentNotRegistered.selector, stranger));
        _activateTestCommitment(stranger, orgId, stranger, 100, 0);
    }

    function test_registeredCommitmentCannotDebitOrgFundsDirectly() public {
        address maliciousCommitment = _deployTestCommitment();
        uint256 availableBefore = commitmentFunds.availableBalance(orgId);
        uint256 recipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.prank(contractOwner);
        commitmentFunds.registerResponseCommitment(maliciousCommitment, 1);

        vm.prank(maliciousCommitment);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.ResponseCommitmentNotCurrent.selector, maliciousCommitment, address(this))
        );
        commitmentFunds.activateCommitment(maliciousCommitment, orgId, 1, availableBefore - 1, feeRecipient, bytes(""));

        assertEq(commitmentFunds.availableBalance(orgId), availableBefore);
        assertEq(usdc.balanceOf(feeRecipient), recipientBalanceBefore);
    }

    function test_activateCommitment_revert_creatorNotCommitmentManager() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.NotCommitmentManager.selector, orgId, stranger));
        _activateTestCommitment(address(this), orgId, stranger, 100, 0);
    }

    function test_activateCommitment_revert_whenPaused() public {
        vm.prank(contractOwner);
        commitmentFunds.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _activateTestCommitment(address(this), orgId, orgOwner1, 500_000_000, 10_000_000);
    }

    function test_depositWithAuthorization_revert_wrongOrgTreasury() public {
        uint256 amount = 1_000_000;

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, stranger));
        commitmentFunds.depositWithAuthorization(orgId, amount, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_depositWithAuthorization_revert_zeroAmount() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        commitmentFunds.depositWithAuthorization(orgId, 0, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_depositWithAuthorization_revert_whenPaused() public {
        uint256 amount = 1_000_000;

        vm.prank(contractOwner);
        commitmentFunds.pause();

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        commitmentFunds.depositWithAuthorization(orgId, amount, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_depositWithAuthorization() public {
        uint256 treasuryPrivateKey = 0xBEEF;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "authorization.test");
        uint256 amount = 125_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("commitment-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) = _signReceiveWithAuthorization(
            address(usdc), address(commitmentFunds), treasuryPrivateKey, amount, validAfter, validBefore, nonce
        );

        usdc.mint(treasury, amount);

        vm.startPrank(treasury);
        vm.expectEmit(true, true, false, true);
        emit ICommitmentFunds.CommitmentFundsDeposited(authorizationOrgId, treasury, amount);
        commitmentFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();

        assertEq(usdc.allowance(treasury, address(commitmentFunds)), 0);
        assertEq(usdc.balanceOf(address(commitmentFunds)), 10_000_000_000 + amount);
        assertEq(commitmentFunds.availableBalance(authorizationOrgId), amount);
        assertTrue(usdc.authorizationState(treasury, nonce));
    }

    function test_depositWithAuthorization_revert_replayedAuthorization() public {
        uint256 treasuryPrivateKey = 0xCAFE;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "replay.test");
        uint256 amount = 1_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("replayed-commitment-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) = _signReceiveWithAuthorization(
            address(usdc), address(commitmentFunds), treasuryPrivateKey, amount, validAfter, validBefore, nonce
        );

        usdc.mint(treasury, amount);

        vm.startPrank(treasury);
        commitmentFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);
        vm.expectRevert(MockUSDC.AuthorizationAlreadyUsed.selector);
        commitmentFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);
        vm.stopPrank();
    }

    function test_depositWithAuthorization_revert_expiredAuthorization() public {
        uint256 treasuryPrivateKey = 0xD00D;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "expired.test");
        uint256 amount = 1_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 minutes;
        bytes32 nonce = keccak256("expired-commitment-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) = _signReceiveWithAuthorization(
            address(usdc), address(commitmentFunds), treasuryPrivateKey, amount, validAfter, validBefore, nonce
        );

        usdc.mint(treasury, amount);
        vm.warp(validBefore);

        vm.prank(treasury);
        vm.expectRevert(MockUSDC.AuthorizationExpired.selector);
        commitmentFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);
    }

    function test_depositWithAuthorization_atValidAfter_preservesStateAndAllowsRetry() public {
        uint256 treasuryPrivateKey = 0xBEEF;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "not-yet-valid.test");
        uint256 amount = 125_000_000;
        uint256 validAfter = block.timestamp + 1 minutes;
        uint256 validBefore = validAfter + 1 hours;
        bytes32 nonce = keccak256("not-yet-valid-commitment-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) = _signReceiveWithAuthorization(
            address(usdc), address(commitmentFunds), treasuryPrivateKey, amount, validAfter, validBefore, nonce
        );
        uint256 tokenBalanceBefore = usdc.balanceOf(address(commitmentFunds));
        uint256 accountedBefore = commitmentFunds.totalAccountedBalance();

        usdc.mint(treasury, amount);
        vm.warp(validAfter);

        vm.prank(treasury);
        vm.expectRevert(MockUSDC.AuthorizationNotYetValid.selector);
        commitmentFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), amount);
        assertEq(usdc.balanceOf(address(commitmentFunds)), tokenBalanceBefore);
        assertEq(commitmentFunds.availableBalance(authorizationOrgId), 0);
        assertEq(commitmentFunds.totalAccountedBalance(), accountedBefore);
        assertFalse(usdc.authorizationState(treasury, nonce));

        vm.warp(validAfter + 1);
        vm.prank(treasury);
        commitmentFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(commitmentFunds)), tokenBalanceBefore + amount);
        assertEq(commitmentFunds.availableBalance(authorizationOrgId), amount);
        assertEq(commitmentFunds.totalAccountedBalance(), accountedBefore + amount);
        assertTrue(usdc.authorizationState(treasury, nonce));
    }

    function test_depositWithAuthorization_wrongAmount_preservesStateAndAllowsRetry() public {
        uint256 treasuryPrivateKey = 0xBEEF;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "wrong-amount.test");
        uint256 amount = 125_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("wrong-amount-commitment-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) = _signReceiveWithAuthorization(
            address(usdc), address(commitmentFunds), treasuryPrivateKey, amount, validAfter, validBefore, nonce
        );
        uint256 tokenBalanceBefore = usdc.balanceOf(address(commitmentFunds));
        uint256 accountedBefore = commitmentFunds.totalAccountedBalance();

        usdc.mint(treasury, amount + 1);

        vm.prank(treasury);
        vm.expectRevert(MockUSDC.InvalidAuthorizationSigner.selector);
        commitmentFunds.depositWithAuthorization(
            authorizationOrgId, amount + 1, validAfter, validBefore, nonce, v, r, s
        );

        assertEq(usdc.balanceOf(treasury), amount + 1);
        assertEq(usdc.balanceOf(address(commitmentFunds)), tokenBalanceBefore);
        assertEq(commitmentFunds.availableBalance(authorizationOrgId), 0);
        assertEq(commitmentFunds.totalAccountedBalance(), accountedBefore);
        assertFalse(usdc.authorizationState(treasury, nonce));

        vm.prank(treasury);
        commitmentFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), 1);
        assertEq(usdc.balanceOf(address(commitmentFunds)), tokenBalanceBefore + amount);
        assertEq(commitmentFunds.availableBalance(authorizationOrgId), amount);
        assertEq(commitmentFunds.totalAccountedBalance(), accountedBefore + amount);
        assertTrue(usdc.authorizationState(treasury, nonce));
    }

    function test_depositWithAuthorization_insufficientTokens_preservesStateAndAllowsRetry() public {
        uint256 treasuryPrivateKey = 0xBEEF;
        address treasury = vm.addr(treasuryPrivateKey);
        uint256 authorizationOrgId = _createOrg(treasury, "insufficient-tokens.test");
        uint256 amount = 125_000_000;
        uint256 validAfter = 0;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("insufficient-tokens-commitment-funds-deposit");
        (uint8 v, bytes32 r, bytes32 s) = _signReceiveWithAuthorization(
            address(usdc), address(commitmentFunds), treasuryPrivateKey, amount, validAfter, validBefore, nonce
        );
        uint256 tokenBalanceBefore = usdc.balanceOf(address(commitmentFunds));
        uint256 accountedBefore = commitmentFunds.totalAccountedBalance();

        usdc.mint(treasury, amount - 1);

        vm.prank(treasury);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, treasury, amount - 1, amount)
        );
        commitmentFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), amount - 1);
        assertEq(usdc.balanceOf(address(commitmentFunds)), tokenBalanceBefore);
        assertEq(commitmentFunds.availableBalance(authorizationOrgId), 0);
        assertEq(commitmentFunds.totalAccountedBalance(), accountedBefore);
        assertFalse(usdc.authorizationState(treasury, nonce));

        usdc.mint(treasury, 1);
        vm.prank(treasury);
        commitmentFunds.depositWithAuthorization(authorizationOrgId, amount, validAfter, validBefore, nonce, v, r, s);

        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(commitmentFunds)), tokenBalanceBefore + amount);
        assertEq(commitmentFunds.availableBalance(authorizationOrgId), amount);
        assertEq(commitmentFunds.totalAccountedBalance(), accountedBefore + amount);
        assertTrue(usdc.authorizationState(treasury, nonce));
    }

    function test_deposit_fromContractTreasury() public {
        ContractTreasury treasury = new ContractTreasury();
        uint256 contractTreasuryOrgId = _createOrg(address(treasury), "contract-treasury.test");
        uint256 amount = 125_000_000;
        uint256 commitmentFundsBalanceBefore = usdc.balanceOf(address(commitmentFunds));
        uint256 totalAccountedBefore = commitmentFunds.totalAccountedBalance();

        usdc.mint(address(treasury), amount);
        treasury.approveToken(usdc, address(commitmentFunds), amount);

        vm.expectEmit(true, true, false, true);
        emit ICommitmentFunds.CommitmentFundsDeposited(contractTreasuryOrgId, address(treasury), amount);
        treasury.depositCommitmentFunds(commitmentFunds, contractTreasuryOrgId, amount);

        assertEq(usdc.allowance(address(treasury), address(commitmentFunds)), 0);
        assertEq(usdc.balanceOf(address(commitmentFunds)), commitmentFundsBalanceBefore + amount);
        assertEq(commitmentFunds.availableBalance(contractTreasuryOrgId), amount);
        assertEq(commitmentFunds.totalAccountedBalance(), totalAccountedBefore + amount);
    }

    function test_deposit_revert_wrongOrgTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, stranger));
        commitmentFunds.deposit(orgId, 1_000_000);
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        commitmentFunds.deposit(orgId, 0);
    }

    function test_deposit_revert_whenPaused() public {
        vm.prank(contractOwner);
        commitmentFunds.pause();

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        commitmentFunds.deposit(orgId, 1_000_000);
    }

    function test_withdraw() public {
        uint256 withdrawAmount = 5_000_000_000;
        uint256 ownerBalanceBefore = usdc.balanceOf(orgOwner1);

        vm.prank(orgOwner1);
        commitmentFunds.withdraw(orgId, withdrawAmount);

        assertEq(usdc.balanceOf(orgOwner1), ownerBalanceBefore + withdrawAmount);
        assertEq(commitmentFunds.availableBalance(orgId), 10_000_000_000 - withdrawAmount);
    }

    function test_withdraw_revert_insufficientAvailable() public {
        uint256 stakeAmount = 6_000_000_000;
        _activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, 0);

        uint256 available = 10_000_000_000 - stakeAmount;

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, available + 1, available));
        commitmentFunds.withdraw(orgId, available + 1);
    }

    function test_withdraw_revert_wrongOrgTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, stranger));
        commitmentFunds.withdraw(orgId, 1);
    }

    function test_setFeeRecipient_updatesFeeDestination() public {
        address newRecipient = makeAddr("newRecipient");
        uint256 feeAmount = 10_000_000;

        vm.prank(contractOwner);
        commitmentFunds.setFeeRecipient(newRecipient);
        feeRecipient = newRecipient;

        _activateTestCommitment(address(this), orgId, orgOwner1, 500_000_000, feeAmount);

        assertEq(usdc.balanceOf(newRecipient), feeAmount);
    }

    function test_setFeeRecipient_emitsEvent() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(contractOwner);
        vm.expectEmit(true, true, false, true);
        emit ICommitmentFunds.FeeRecipientUpdated(feeRecipient, newRecipient);
        commitmentFunds.setFeeRecipient(newRecipient);
    }

    function test_setFeeRecipient_revert_zeroAddress() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        commitmentFunds.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_revert_notOwner() public {
        address newRecipient = makeAddr("newRecipient");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        commitmentFunds.setFeeRecipient(newRecipient);
    }

    function test_setFeeRecipient_revert_selfAddress() public {
        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidFeeRecipient.selector, address(commitmentFunds)));
        commitmentFunds.setFeeRecipient(address(commitmentFunds));
    }

    function test_activateCommitment_revert_registeredNonCurrentCommitment() public {
        address oldCommitment = _deployTestCommitment();

        vm.prank(contractOwner);
        commitmentFunds.registerResponseCommitment(oldCommitment, 1);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.ResponseCommitmentNotCurrent.selector, oldCommitment, address(this))
        );
        _activateTestCommitment(oldCommitment, orgId, orgOwner1, 100, 0);
    }

    function test_nonCurrentCommitment_settlesExistingLock() public {
        address oldCommitment = _deployTestCommitment();
        uint256 commitmentId = 1;
        uint256 stakeAmount = 500_000_000;

        vm.startPrank(contractOwner);
        commitmentFunds.registerResponseCommitment(oldCommitment, 1);
        commitmentFunds.setCurrentResponseCommitment(oldCommitment);
        vm.stopPrank();

        assertEq(_activateTestCommitment(oldCommitment, orgId, orgOwner1, stakeAmount, 0), commitmentId);

        vm.prank(contractOwner);
        commitmentFunds.setCurrentResponseCommitment(address(this));

        vm.expectRevert(
            abi.encodeWithSelector(Errors.ResponseCommitmentNotCurrent.selector, oldCommitment, address(this))
        );
        _activateTestCommitment(oldCommitment, orgId, orgOwner1, stakeAmount, 0);

        vm.prank(oldCommitment);
        commitmentFunds.settleCommitment(orgId, commitmentId, stakeAmount);

        CommitmentLock memory lock = commitmentFunds.commitmentLock(oldCommitment, commitmentId);
        assertEq(lock.stakeAmount, 0);
    }

    function test_activateCommitment_revert_insufficientBalance() public {
        uint256 available = 10_000_000_000;
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, available + 1, available));
        _activateTestCommitment(address(this), orgId, orgOwner1, available + 1, 0);
    }

    function test_activateCommitment_revert_orgNotFound() public {
        uint256 fakeOrgId = 999;

        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, fakeOrgId));
        _activateTestCommitment(address(this), fakeOrgId, orgOwner1, 100, 0);
    }

    function test_activateCommitment_revert_zeroStakeAmount() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        _activateTestCommitment(address(this), orgId, orgOwner1, 0, 10_000_000);
    }

    function test_settleCommitment_fullReturn() public {
        uint256 stakeAmount = 500_000_000;
        uint256 commitmentId = 1;
        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, 0), commitmentId);

        commitmentFunds.settleCommitment(orgId, commitmentId, stakeAmount);

        OrgCommitmentBalance memory balance = commitmentFunds.commitmentBalance(orgId);
        CommitmentLock memory lock = commitmentFunds.commitmentLock(address(this), commitmentId);
        assertEq(lock.stakeAmount, 0);
        assertEq(balance.lockedInCommitments, 0);
        assertEq(balance.available, 10_000_000_000);
        assertEq(commitmentFunds.availableBalance(orgId), 10_000_000_000);
    }

    function test_settleCommitment_partialReturn() public {
        uint256 stakeAmount = 500_000_000;
        uint256 returnAmount = 400_000_000;
        uint256 slashedAmount = 100_000_000;
        uint256 commitmentId = 1;

        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, 0), commitmentId);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);
        commitmentFunds.settleCommitment(orgId, commitmentId, returnAmount);

        OrgCommitmentBalance memory balance = commitmentFunds.commitmentBalance(orgId);
        assertEq(balance.lockedInCommitments, 0);
        assertEq(balance.available, 10_000_000_000 - slashedAmount);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalBefore, slashedAmount, "Slash mismatch");
    }

    function test_settleCommitment_zeroReturn() public {
        uint256 stakeAmount = 500_000_000;
        uint256 commitmentId = 1;
        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, 0), commitmentId);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);
        commitmentFunds.settleCommitment(orgId, commitmentId, 0);

        OrgCommitmentBalance memory balance = commitmentFunds.commitmentBalance(orgId);
        assertEq(balance.lockedInCommitments, 0);
        assertEq(balance.available, 10_000_000_000 - stakeAmount);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalBefore, stakeAmount, "Slash mismatch");
    }

    function test_settleCommitment_emitsEvent() public {
        uint256 stakeAmount = 500_000_000;
        uint256 commitmentId = 1;
        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, 0), commitmentId);

        vm.expectEmit(true, true, true, true);
        emit ICommitmentFunds.StakeBurned(address(this), orgId, commitmentId, 200_000_000);
        vm.expectEmit(true, true, true, true);
        emit ICommitmentFunds.CommitmentStakeSettled(address(this), orgId, commitmentId, 300_000_000, 200_000_000);
        commitmentFunds.settleCommitment(orgId, commitmentId, 300_000_000);
    }

    function test_settleCommitment_revert_unknownCommitment() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.ResponseCommitmentNotRegistered.selector, stranger));
        commitmentFunds.settleCommitment(orgId, 1, 100);
    }

    function test_settleCommitment_revert_orgMismatch() public {
        uint256 secondOrgId = _createOrg(orgOwner2, "second.com");
        uint256 stakeAmount = 500_000_000;
        uint256 commitmentId = 1;

        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, 0), commitmentId);

        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentLockOrgMismatch.selector, secondOrgId, orgId));
        commitmentFunds.settleCommitment(secondOrgId, commitmentId, stakeAmount);
    }

    function test_settleCommitment_allowedWhenPaused() public {
        uint256 stakeAmount = 500_000_000;
        uint256 commitmentId = 1;

        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, 0), commitmentId);

        vm.prank(contractOwner);
        commitmentFunds.pause();

        commitmentFunds.settleCommitment(orgId, commitmentId, stakeAmount);

        OrgCommitmentBalance memory balance = commitmentFunds.commitmentBalance(orgId);
        assertEq(balance.lockedInCommitments, 0);
    }

    function test_settleCommitment_revert_exceedsLockedAmount() public {
        uint256 stakeAmount = 500_000_000;
        uint256 commitmentId = 1;
        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stakeAmount, 0), commitmentId);

        uint256 returnAmount = stakeAmount + 100_000_000;

        vm.expectRevert(abi.encodeWithSelector(Errors.ExceedsLockedAmount.selector, returnAmount, stakeAmount));
        commitmentFunds.settleCommitment(orgId, commitmentId, returnAmount);
    }

    function test_settleCommitment_revert_commitmentNotLocked() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentNotLocked.selector, address(this), 999));
        commitmentFunds.settleCommitment(orgId, 999, 0);
    }

    function test_activateCommitment_revert_commitmentAlreadyLocked() public {
        address repeatedIdCommitment = _deployTestCommitment();
        uint256 commitmentId = 1;

        vm.startPrank(contractOwner);
        commitmentFunds.registerResponseCommitment(repeatedIdCommitment, 1);
        commitmentFunds.setCurrentResponseCommitment(repeatedIdCommitment);
        vm.stopPrank();

        assertEq(_activateTestCommitment(repeatedIdCommitment, orgId, orgOwner1, 500_000_000, 0), commitmentId);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.CommitmentAlreadyLocked.selector, repeatedIdCommitment, commitmentId)
        );
        _activateTestCommitment(repeatedIdCommitment, orgId, orgOwner1, 300_000_000, 0);
    }

    function test_registerResponseCommitment_revert_duplicate() public {
        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ResponseCommitmentAlreadyRegistered.selector, address(this)));
        commitmentFunds.registerResponseCommitment(address(this), 1);
    }

    function test_registerResponseCommitment_revert_notOwner() public {
        address newCommitment = _deployTestCommitment();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        commitmentFunds.registerResponseCommitment(newCommitment, 1);
    }

    function test_registerResponseCommitment_revert_missingRegistrationGetters() public {
        address badCommitment = address(new CommitmentWithoutRegistration());

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidResponseCommitment.selector, badCommitment));
        commitmentFunds.registerResponseCommitment(badCommitment, 1);
    }

    function test_registerResponseCommitment_revert_wrongCommitmentFunds() public {
        address badCommitment =
            address(new TestCommitmentRegistration(ICommitmentFunds(makeAddr("wrongCommitmentFunds"))));

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidResponseCommitment.selector, badCommitment));
        commitmentFunds.registerResponseCommitment(badCommitment, 1);
    }

    function test_setCurrentResponseCommitment_revert_notFound() public {
        address unknownCommitment = _deployTestCommitment();

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ResponseCommitmentNotRegistered.selector, unknownCommitment));
        commitmentFunds.setCurrentResponseCommitment(unknownCommitment);
    }

    function test_setCurrentResponseCommitment_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        commitmentFunds.setCurrentResponseCommitment(address(this));
    }

    function test_setCurrentResponseCommitment_revert_zeroAddress() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        commitmentFunds.setCurrentResponseCommitment(address(0));
    }

    function test_setCurrentResponseCommitment_revalidatesRegisteredVersion() public {
        MutableCommitmentRegistration mutableCommitment = new MutableCommitmentRegistration(commitmentFunds);

        vm.prank(contractOwner);
        commitmentFunds.registerResponseCommitment(address(mutableCommitment), 1);

        mutableCommitment.setCommitmentVersion(2);

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidResponseCommitment.selector, address(mutableCommitment)));
        commitmentFunds.setCurrentResponseCommitment(address(mutableCommitment));

        assertEq(commitmentFunds.currentResponseCommitment(), address(this));
    }

    function test_registerResponseCommitment_revert_eoaAddress() public {
        address notContract = makeAddr("notContract");

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ContractExpected.selector, notContract));
        commitmentFunds.registerResponseCommitment(notContract, 1);
    }

    function test_sameCommitmentIdFromDifferentCommitmentsUsesSeparateLocks() public {
        address secondCommitment = _deployTestCommitment();
        uint256 commitmentId = 1;
        uint256 firstStake = 500_000_000;
        uint256 secondStake = 300_000_000;

        vm.prank(contractOwner);
        commitmentFunds.registerResponseCommitment(secondCommitment, 1);

        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, firstStake, 0), commitmentId);

        vm.prank(contractOwner);
        commitmentFunds.setCurrentResponseCommitment(secondCommitment);

        assertEq(_activateTestCommitment(secondCommitment, orgId, orgOwner1, secondStake, 0), commitmentId);

        CommitmentLock memory firstLock = commitmentFunds.commitmentLock(address(this), commitmentId);
        CommitmentLock memory secondLock = commitmentFunds.commitmentLock(secondCommitment, commitmentId);

        assertEq(firstLock.orgId, orgId);
        assertEq(firstLock.stakeAmount, firstStake);
        assertEq(secondLock.orgId, orgId);
        assertEq(secondLock.stakeAmount, secondStake);

        commitmentFunds.settleCommitment(orgId, commitmentId, firstStake);

        firstLock = commitmentFunds.commitmentLock(address(this), commitmentId);
        secondLock = commitmentFunds.commitmentLock(secondCommitment, commitmentId);

        assertEq(firstLock.stakeAmount, 0);
        assertEq(secondLock.stakeAmount, secondStake);
    }

    function test_multipleCommitments_lockAndRelease() public {
        uint256 commitment1Stake = 500_000_000;
        uint256 commitment2Stake = 300_000_000;
        uint256 commitmentId1 = 1;
        uint256 commitmentId2 = 2;

        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, commitment1Stake, 0), commitmentId1);
        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, commitment2Stake, 0), commitmentId2);

        OrgCommitmentBalance memory balance = commitmentFunds.commitmentBalance(orgId);
        assertEq(balance.lockedInCommitments, commitment1Stake + commitment2Stake);
        assertEq(balance.available, 10_000_000_000 - commitment1Stake - commitment2Stake);

        commitmentFunds.settleCommitment(orgId, commitmentId1, commitment1Stake);

        balance = commitmentFunds.commitmentBalance(orgId);
        assertEq(balance.lockedInCommitments, commitment2Stake);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);
        commitmentFunds.settleCommitment(orgId, commitmentId2, 200_000_000);

        balance = commitmentFunds.commitmentBalance(orgId);
        assertEq(balance.lockedInCommitments, 0);
        assertEq(balance.available, 10_000_000_000 - 100_000_000);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalBefore, 100_000_000, "Slash mismatch");
    }

    function test_rescueTokens_revert_notOwner() public {
        usdc.mint(address(commitmentFunds), 1_000_000);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        commitmentFunds.rescueTokens(address(usdc), stranger, 1);
    }

    function test_rescueTokens_revert_zeroRecipient() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        commitmentFunds.rescueTokens(address(usdc), address(0), 0);
    }

    function test_rescueTokens_otherToken_rescuesFullBalance() public {
        USDC otherToken = new USDC();
        uint256 amount = 1_000_000;
        address rescueTo = makeAddr("rescueRecipient");

        otherToken.mint(address(commitmentFunds), amount);

        vm.prank(contractOwner);
        commitmentFunds.rescueTokens(address(otherToken), rescueTo, amount);

        assertEq(otherToken.balanceOf(rescueTo), amount);
        assertEq(otherToken.balanceOf(address(commitmentFunds)), 0);
    }

    function test_rescueTokens_stakeToken_rescuesExactSurplus() public {
        uint256 surplus = 1_000_000;
        uint256 accounted = commitmentFunds.totalAccountedBalance();
        address rescueTo = makeAddr("rescueRecipient");

        usdc.mint(address(commitmentFunds), surplus);

        vm.prank(contractOwner);
        commitmentFunds.rescueTokens(address(usdc), rescueTo, surplus);

        assertEq(usdc.balanceOf(rescueTo), surplus);
        assertEq(usdc.balanceOf(address(commitmentFunds)), accounted);
        assertEq(commitmentFunds.totalAccountedBalance(), accounted);
    }

    function test_rescueTokens_stakeToken_revert_aboveSurplus() public {
        uint256 surplus = 1_000_000;
        uint256 requested = surplus + 1;

        usdc.mint(address(commitmentFunds), surplus);

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueExceedsSurplus.selector, requested, surplus));
        commitmentFunds.rescueTokens(address(usdc), makeAddr("rescueRecipient"), requested);
    }
}
