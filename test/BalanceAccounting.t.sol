// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "./shared/TestBase.sol";
import {JobView} from "../src/interfaces/IJobCommitment.sol";
import {OrgJobBalance} from "../src/interfaces/IJobFunds.sol";

/// @title BalanceAccountingTest
/// @notice Tests that totalApplicantStakes and totalAccountedBalance track correctly
contract BalanceAccountingTest is JobCommitmentTestBase {
    // ============ totalApplicantStakes ============

    function test_totalApplicantStakes_incrementsOnApply() public {
        _publishJob(0);
        assertEq(jobCommitment.totalApplicantStakes(), 0);

        _applyToJob(1, applicant1);
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE);

        _applyToJob(1, applicant2);
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE * 2);
    }

    function test_totalApplicantStakes_decrementsOnWithdraw() public {
        _publishJob(0);
        bytes32 appId1 = _applyToJob(1, applicant1);
        bytes32 appId2 = _applyToJob(1, applicant2);
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE * 2);

        _respondToApplication(appId1);
        _respondToApplication(appId2);

        _withdrawStake(appId1, applicant1);
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE);

        _withdrawStake(appId2, applicant2);
        assertEq(jobCommitment.totalApplicantStakes(), 0);
    }

    function test_totalApplicantStakes_matchesTokenBalance() public {
        _publishJob(0);
        bytes32 appId1 = _applyToJob(1, applicant1);
        _applyToJob(1, applicant2);

        // Token balance should equal totalApplicantStakes
        assertEq(usdc.balanceOf(address(jobCommitment)), jobCommitment.totalApplicantStakes());

        _respondToApplication(appId1);
        _withdrawStake(appId1, applicant1);

        // After partial withdrawal, still matches
        assertEq(usdc.balanceOf(address(jobCommitment)), jobCommitment.totalApplicantStakes());
    }

    function test_totalApplicantStakes_preservesAmountsAcrossUpdate() public {
        _publishJob(0);

        bytes32 oldAmountApp = _applyToJobWithStake(applicant1, APPLICANT_STAKE);
        uint96 newApplicantStake = 7_000_000;

        vm.prank(owner);
        jobCommitment.setApplicantStakeAmount(newApplicantStake);

        bytes32 newAmountApp = _applyToJobWithStake(applicant2, newApplicantStake);
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE + newApplicantStake);

        _respondToApplication(oldAmountApp);
        _respondToApplication(newAmountApp);
        _withdrawStake(oldAmountApp, applicant1);
        _withdrawStake(newAmountApp, applicant2);
        assertEq(jobCommitment.totalApplicantStakes(), 0);
    }

    function test_totalApplicantStakes_fullLifecycle() public {
        uint256 jobId = _publishJob(0);

        // 2 applicants apply
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        bytes32 appId2 = _applyToJob(jobId, applicant2);
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE * 2);

        // Respond + close job
        _respondToApplication(appId1);
        _respondToApplication(appId2);
        _unpublishJob(jobId);
        _closeJob(jobId, 2, 2, 2);

        // Applicant stakes still tracked (not withdrawn yet)
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE * 2);

        // Withdraw both
        _withdrawStake(appId1, applicant1);
        _withdrawStake(appId2, applicant2);
        assertEq(jobCommitment.totalApplicantStakes(), 0);
        assertEq(usdc.balanceOf(address(jobCommitment)), 0);
    }

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

        // totalAccounted decreases by fee only; stake remains accounted in the jobFunds.
        assertEq(jobFunds.totalAccountedBalance(), before - job.feeAmount);
    }

    function test_totalAccountedBalance_decrementsOnSlash() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);
        _respondToApplication(appId);

        uint256 before = jobFunds.totalAccountedBalance();

        // Close with 1 total, 1 responded, 0 on-time → soft slash
        _unpublishJob(jobId);
        _closeJob(jobId, 1, 1, 0);

        uint256 after_ = jobFunds.totalAccountedBalance();

        // totalAccounted decreased by slashed amount
        assertTrue(after_ < before, "Should decrease after slash");
    }

    function test_totalAccountedBalance_matchesTokenBalance() public {
        // After setup: jobFunds token balance should equal totalAccountedBalance.
        assertEq(usdc.balanceOf(address(jobFunds)), jobFunds.totalAccountedBalance());

        // After creating a job (fee deducted)
        _publishJob(0);
        assertEq(usdc.balanceOf(address(jobFunds)), jobFunds.totalAccountedBalance());

        // After withdrawal
        vm.prank(employer);
        jobFunds.withdraw(DEFAULT_ORG_ID, 1_000_000);
        assertEq(usdc.balanceOf(address(jobFunds)), jobFunds.totalAccountedBalance());
    }

    function test_totalAccountedBalance_multipleOrgs() public {
        // Create second org
        uint256 employer2PrivateKey = 0xE22CE;
        address employer2 = vm.addr(employer2PrivateKey);
        _createOrgForEmployer(employer2, "other.com", 2);

        uint256 deposit2 = 5_000_000_000; // 5000 USDC
        _fundOrg(2, employer2PrivateKey, deposit2);

        // totalAccounted = org1 balance + org2 balance
        OrgJobBalance memory org1 = jobFunds.jobBalance(DEFAULT_ORG_ID);
        OrgJobBalance memory org2 = jobFunds.jobBalance(2);
        uint256 org1Total = uint256(org1.available) + org1.stakedInJobs;
        uint256 org2Total = uint256(org2.available) + org2.stakedInJobs;
        assertEq(jobFunds.totalAccountedBalance(), org1Total + org2Total);
    }

    // ============ Combined: both invariants through full lifecycle ============

    function test_bothInvariants_fullLifecycle() public {
        uint256 jobId = _publishJob(0);
        JobView memory job = jobCommitment.job(jobId);

        // After job creation: org balance decreased by fee, applicant stakes = 0
        assertEq(jobFunds.totalAccountedBalance(), ORG_OPERATIONAL_BALANCE - job.feeAmount);
        assertEq(jobCommitment.totalApplicantStakes(), 0);

        // Apply
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        bytes32 appId2 = _applyToJob(jobId, applicant2);
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE * 2);

        // Respond + close
        _respondToApplication(appId1);
        _respondToApplication(appId2);
        _unpublishJob(jobId);
        _closeJob(jobId, 2, 2, 2);

        // After close (100% on-time = no slash): org balance restored minus fee
        assertEq(jobFunds.totalAccountedBalance(), ORG_OPERATIONAL_BALANCE - job.feeAmount);

        // Withdraw applicant stakes
        _withdrawStake(appId1, applicant1);
        _withdrawStake(appId2, applicant2);
        assertEq(jobCommitment.totalApplicantStakes(), 0);

        // Final: both token balances match their counters
        assertEq(usdc.balanceOf(address(jobCommitment)), 0);
        assertEq(usdc.balanceOf(address(jobFunds)), jobFunds.totalAccountedBalance());
    }
}
