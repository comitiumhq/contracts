// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {OrgCommitmentBalance} from "../../src/interfaces/ICommitmentFunds.sol";
import {Errors} from "../../src/Errors.sol";

import {OrgTestBase} from "../shared/OrgTestBase.sol";

contract OrgBalanceFuzzTest is OrgTestBase {
    uint256 orgId;

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "fuzz.com");
        vm.startPrank(contractOwner);
        commitmentFunds.registerResponseCommitment(address(this), 1);
        commitmentFunds.setCurrentResponseCommitment(address(this));
        vm.stopPrank();
    }

    function testFuzz_depositThenFullWithdraw(uint256 amount) public {
        amount = bound(amount, 1, type(uint96).max);

        _fundAndDeposit(orgId, orgOwner1, amount);

        vm.prank(orgOwner1);
        commitmentFunds.withdraw(orgId, amount);

        assertEq(commitmentFunds.availableBalance(orgId), 0);
    }

    function testFuzz_multipleDeposits(uint256 a, uint256 b) public {
        a = bound(a, 1, type(uint96).max / 2);
        b = bound(b, 1, type(uint96).max / 2);

        _fundAndDeposit(orgId, orgOwner1, a);
        _fundAndDeposit(orgId, orgOwner1, b);

        assertEq(commitmentFunds.availableBalance(orgId), a + b);
    }

    function testFuzz_withdrawCappedByAvailable(uint256 deposit, uint256 stake, uint256 withdrawAttempt) public {
        deposit = bound(deposit, 2, type(uint96).max / 2);
        stake = bound(stake, 1, deposit - 1);
        _fundAndDeposit(orgId, orgOwner1, deposit);

        _activateTestCommitment(address(this), orgId, orgOwner1, stake, 0);

        uint256 available = commitmentFunds.availableBalance(orgId);
        withdrawAttempt = bound(withdrawAttempt, available + 1, type(uint96).max);

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, withdrawAttempt, available));
        commitmentFunds.withdraw(orgId, withdrawAttempt);
    }

    function testFuzz_fundAndSettlePartialReturn(uint256 stake, uint256 returnAmount) public {
        stake = bound(stake, 1, type(uint96).max / 4);
        returnAmount = bound(returnAmount, 0, stake);

        _fundAndDeposit(orgId, orgOwner1, stake);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);

        _activateTestCommitment(address(this), orgId, orgOwner1, stake, 0);
        commitmentFunds.settleCommitment(orgId, 1, returnAmount);

        uint256 slashed = stake - returnAmount;

        OrgCommitmentBalance memory org = commitmentFunds.commitmentBalance(orgId);
        assertEq(org.lockedInCommitments, 0);
        assertEq(org.available, stake - slashed);
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, slashed, "Slash mismatch");
    }

    function testFuzz_settleCommitment_cannotExceedLocked(uint256 stake, uint256 extra) public {
        stake = bound(stake, 1, type(uint96).max / 4);
        extra = bound(extra, 1, type(uint96).max / 4);

        _fundAndDeposit(orgId, orgOwner1, stake);
        _activateTestCommitment(address(this), orgId, orgOwner1, stake, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.ExceedsLockedAmount.selector, stake + extra, stake));
        commitmentFunds.settleCommitment(orgId, 1, stake + extra);
    }

    function testFuzz_multipleCommitments(uint256 stake1, uint256 stake2, uint256 return1, uint256 return2) public {
        stake1 = bound(stake1, 1, type(uint96).max / 8);
        stake2 = bound(stake2, 1, type(uint96).max / 8);
        return1 = bound(return1, 0, stake1);
        return2 = bound(return2, 0, stake2);

        _fundAndDeposit(orgId, orgOwner1, stake1 + stake2);

        _activateTestCommitment(address(this), orgId, orgOwner1, stake1, 0);
        _activateTestCommitment(address(this), orgId, orgOwner1, stake2, 0);

        OrgCommitmentBalance memory mid = commitmentFunds.commitmentBalance(orgId);
        assertEq(mid.lockedInCommitments, stake1 + stake2);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);

        commitmentFunds.settleCommitment(orgId, 1, return1);
        commitmentFunds.settleCommitment(orgId, 2, return2);

        uint256 totalSlashed = (stake1 - return1) + (stake2 - return2);

        OrgCommitmentBalance memory after_ = commitmentFunds.commitmentBalance(orgId);
        assertEq(after_.lockedInCommitments, 0);
        assertEq(after_.available, stake1 + stake2 - totalSlashed);
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, totalSlashed, "Slash mismatch");
    }
}
