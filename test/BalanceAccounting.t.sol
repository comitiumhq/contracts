// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "./shared/TestBase.sol";
import {CommitmentView} from "../src/interfaces/IResponseCommitment.sol";
import {OrgCommitmentBalance} from "../src/interfaces/ICommitmentFunds.sol";

/// @title BalanceAccountingTest
/// @notice Tests that organization funds remain fully accounted for.
contract BalanceAccountingTest is ResponseCommitmentTestBase {
    // ============ totalAccountedBalance ============

    function test_totalAccountedBalance_incrementsOnDeposit() public {
        uint256 before = commitmentFunds.totalAccountedBalance();
        uint256 depositAmount = 1_000_000_000; // 1000 USDC

        _fundOrg(DEFAULT_ORG_ID, employerPrivateKey, depositAmount);

        assertEq(commitmentFunds.totalAccountedBalance(), before + depositAmount);
    }

    function test_totalAccountedBalance_decrementsOnWithdraw() public {
        uint256 before = commitmentFunds.totalAccountedBalance();
        uint256 withdrawAmount = 1_000_000_000;

        vm.prank(employer);
        commitmentFunds.withdraw(DEFAULT_ORG_ID, withdrawAmount);

        assertEq(commitmentFunds.totalAccountedBalance(), before - withdrawAmount);
    }

    function test_totalAccountedBalance_decrementsOnFee() public {
        uint256 before = commitmentFunds.totalAccountedBalance();

        uint256 commitmentId = _activateCommitment(0); // fee tier 0 = 1.5%
        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);

        assertEq(commitmentFunds.totalAccountedBalance(), before - commitment.feeAmount);
    }

    function test_totalAccountedBalance_decrementsOnSlash() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 before = commitmentFunds.totalAccountedBalance();

        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId, 1, 1, 0);

        uint256 after_ = commitmentFunds.totalAccountedBalance();

        assertTrue(after_ < before, "Should decrease after slash");
    }

    function test_totalAccountedBalance_matchesTokenBalance() public {
        assertEq(usdc.balanceOf(address(commitmentFunds)), commitmentFunds.totalAccountedBalance());

        _activateCommitment(0);
        assertEq(usdc.balanceOf(address(commitmentFunds)), commitmentFunds.totalAccountedBalance());

        vm.prank(employer);
        commitmentFunds.withdraw(DEFAULT_ORG_ID, 1_000_000);
        assertEq(usdc.balanceOf(address(commitmentFunds)), commitmentFunds.totalAccountedBalance());
    }

    function test_totalAccountedBalance_multipleOrgs() public {
        uint256 employer2PrivateKey = 0xE22CE;
        address employer2 = vm.addr(employer2PrivateKey);
        _createOrgForEmployer(employer2, "other.com", 2);

        uint256 deposit2 = 5_000_000_000; // 5000 USDC
        _fundOrg(2, employer2PrivateKey, deposit2);

        OrgCommitmentBalance memory org1 = commitmentFunds.commitmentBalance(DEFAULT_ORG_ID);
        OrgCommitmentBalance memory org2 = commitmentFunds.commitmentBalance(2);
        uint256 org1Total = uint256(org1.available) + org1.lockedInCommitments;
        uint256 org2Total = uint256(org2.available) + org2.lockedInCommitments;
        assertEq(commitmentFunds.totalAccountedBalance(), org1Total + org2Total);
    }
}
