// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICommitmentFunds, OrgCommitmentBalance} from "../../src/interfaces/ICommitmentFunds.sol";
import {Errors} from "../../src/Errors.sol";

import {OrgTestBase} from "../shared/OrgTestBase.sol";

contract OrgBalanceTest is OrgTestBase {
    uint256 orgId;

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "test.com");

        vm.startPrank(contractOwner);
        commitmentFunds.registerResponseCommitment(address(this), 1);
        commitmentFunds.setCurrentResponseCommitment(address(this));
        vm.stopPrank();
    }

    function test_depositWithAuthorization() public {
        uint256 amount = 10_000_000_000;
        _fundAndDeposit(orgId, orgOwner1, amount);

        OrgCommitmentBalance memory balance = commitmentFunds.commitmentBalance(orgId);
        assertEq(balance.available, amount);
        assertEq(balance.lockedInCommitments, 0);
        assertEq(commitmentFunds.availableBalance(orgId), amount);
    }

    function test_depositWithAuthorization_revert_notOrgTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, stranger));
        commitmentFunds.depositWithAuthorization(orgId, 1_000_000, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_depositWithAuthorization_revert_zeroAmount() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        commitmentFunds.depositWithAuthorization(orgId, 0, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);
    }

    function test_withdrawStake() public {
        uint256 depositAmount = 10_000_000_000;
        _fundAndDeposit(orgId, orgOwner1, depositAmount);

        uint256 withdrawAmount = 5_000_000_000;
        uint256 balBefore = usdc.balanceOf(orgOwner1);

        vm.prank(orgOwner1);
        commitmentFunds.withdraw(orgId, withdrawAmount);

        assertEq(usdc.balanceOf(orgOwner1), balBefore + withdrawAmount);
        assertEq(commitmentFunds.availableBalance(orgId), depositAmount - withdrawAmount);
    }

    function test_withdraw_afterTreasuryRotation_sendsToCurrentTreasury() public {
        uint256 depositAmount = 10_000_000_000;
        address newTreasury = makeAddr("newTreasury");

        _fundAndDeposit(orgId, orgOwner1, depositAmount);

        vm.prank(orgOwner1);
        registry.proposeOrgTreasuryTransfer(orgId, newTreasury);

        vm.prank(newTreasury);
        registry.acceptOrgTreasuryTransfer(orgId);

        vm.prank(orgOwner1);
        registry.finalizeOrgTreasuryTransfer(orgId);

        uint256 oldTreasuryBalanceBefore = usdc.balanceOf(orgOwner1);
        uint256 newTreasuryBalanceBefore = usdc.balanceOf(newTreasury);

        vm.prank(newTreasury);
        commitmentFunds.withdraw(orgId, depositAmount);

        assertEq(usdc.balanceOf(orgOwner1), oldTreasuryBalanceBefore);
        assertEq(usdc.balanceOf(newTreasury), newTreasuryBalanceBefore + depositAmount);
        assertEq(commitmentFunds.availableBalance(orgId), 0);
    }

    function test_withdraw_emitsEvent() public {
        uint256 depositAmount = 10_000_000_000;
        _fundAndDeposit(orgId, orgOwner1, depositAmount);

        vm.expectEmit(true, true, true, true);
        emit ICommitmentFunds.CommitmentFundsWithdrawn(orgId, orgOwner1, 1_000_000_000);

        vm.prank(orgOwner1);
        commitmentFunds.withdraw(orgId, 1_000_000_000);
    }

    function test_withdraw_revert_insufficientBalance() public {
        uint256 depositAmount = 10_000_000_000;
        _fundAndDeposit(orgId, orgOwner1, depositAmount);

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, depositAmount + 1, depositAmount));
        commitmentFunds.withdraw(orgId, depositAmount + 1);
    }

    function test_withdraw_cannotWithdrawMoreThanAvailable() public {
        uint256 depositAmount = 10_000_000_000;
        _fundAndDeposit(orgId, orgOwner1, depositAmount);

        uint256 lockAmount = 5_000_000_000;
        _activateTestCommitment(address(this), orgId, orgOwner1, lockAmount, 0);

        uint256 available = depositAmount - lockAmount;
        vm.prank(orgOwner1);
        commitmentFunds.withdraw(orgId, available);

        vm.prank(orgOwner1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 1, 0));
        commitmentFunds.withdraw(orgId, 1);
    }

    function test_withdraw_revert_notOrgTreasury() public {
        _fundAndDeposit(orgId, orgOwner1, 10_000_000_000);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, stranger));
        commitmentFunds.withdraw(orgId, 1_000_000);
    }

    function test_withdraw_revert_zeroAmount() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAmount.selector);
        commitmentFunds.withdraw(orgId, 0);
    }
}
