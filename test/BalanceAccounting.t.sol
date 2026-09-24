// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "./shared/TestBase.sol";
import {JobView} from "../src/interfaces/IJobCommitment.sol";
import {OrgJobBalance} from "../src/interfaces/IJobFunds.sol";

/// @title BalanceAccountingTest
/// @notice Tests that organization funds remain fully accounted for.
contract BalanceAccountingTest is JobCommitmentTestBase {
    // ============ totalAccountedBalance ============

    function test_totalAccountedBalance_incrementsOnDeposit() public {
        uint256 before = jobFunds.totalAccountedBalance();
        uint256 depositAmount = 1_000_000_000; // 1000 USDC

        _fundOrg(DEFAULT_ORG_ID, employerPrivateKey, depositAmount);

        assertEq(jobFunds.totalAccountedBalance(), before + depositAmount);
    }

    function test_totalAccountedBalance_decrementsOnWithdraw() public {
        uint256 before = jobFunds.totalAccountedBalance();
        uint256 withdrawAmount = 1_000_000_000;

        vm.prank(employer);
        jobFunds.withdraw(DEFAULT_ORG_ID, withdrawAmount);

        assertEq(jobFunds.totalAccountedBalance(), before - withdrawAmount);
    }

    function test_totalAccountedBalance_decrementsOnFee() public {
        uint256 before = jobFunds.totalAccountedBalance();

        uint256 jobId = _publishJob(0); // fee tier 0 = 1.5%
        JobView memory job = jobCommitment.job(jobId);

        assertEq(jobFunds.totalAccountedBalance(), before - job.feeAmount);
    }

    function test_totalAccountedBalance_decrementsOnSlash() public {
        uint256 jobId = _publishJob(0);
        uint256 before = jobFunds.totalAccountedBalance();

        _unpublishJob(jobId);
        _closeJob(jobId, 1, 1, 0);

        uint256 after_ = jobFunds.totalAccountedBalance();

        assertTrue(after_ < before, "Should decrease after slash");
    }

    function test_totalAccountedBalance_matchesTokenBalance() public {
        assertEq(usdc.balanceOf(address(jobFunds)), jobFunds.totalAccountedBalance());

        _publishJob(0);
        assertEq(usdc.balanceOf(address(jobFunds)), jobFunds.totalAccountedBalance());

        vm.prank(employer);
        jobFunds.withdraw(DEFAULT_ORG_ID, 1_000_000);
        assertEq(usdc.balanceOf(address(jobFunds)), jobFunds.totalAccountedBalance());
    }

    function test_totalAccountedBalance_multipleOrgs() public {
        uint256 employer2PrivateKey = 0xE22CE;
        address employer2 = vm.addr(employer2PrivateKey);
        _createOrgForEmployer(employer2, "other.com", 2);

        uint256 deposit2 = 5_000_000_000; // 5000 USDC
        _fundOrg(2, employer2PrivateKey, deposit2);

        OrgJobBalance memory org1 = jobFunds.jobBalance(DEFAULT_ORG_ID);
        OrgJobBalance memory org2 = jobFunds.jobBalance(2);
        uint256 org1Total = uint256(org1.available) + org1.stakedInJobs;
        uint256 org2Total = uint256(org2.available) + org2.stakedInJobs;
        assertEq(jobFunds.totalAccountedBalance(), org1Total + org2Total);
    }
}
