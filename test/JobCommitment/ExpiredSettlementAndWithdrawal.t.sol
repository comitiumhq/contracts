// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {JobView, ApplicationView} from "../../src/interfaces/IJobCommitment.sol";
import {JobExpiryStatus, JobStatus} from "../../src/types/JobTypes.sol";
import {TEST_MAX_UNPUBLISHED_DURATION, TEST_MAX_PUBLISHED_DURATION} from "../shared/TestBase.sol";

/// @title ExpiredSettlementAndWithdrawalTest
/// @notice Tests expired settlement behavior and applicant withdrawal conditions
/// @dev Covers all slashing tiers, forced expiry closure, withdrawal conditions, and view function edge cases.
contract ExpiredSettlementAndWithdrawalTest is JobCommitmentTestBase {
    // ============ Expired Settlement: All Slashing Tiers ============

    /// @notice 100% on-time response via settleExpiredJob when the employer did not close normally.
    function test_settleExpiredJob_100pctResponse_0pctSlash() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);
        _respondToApplication(appId);

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 burnBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        _settleExpiredJob(jobId, 1, 1, 1);

        assertEq(usdc.balanceOf(SLASH_BURN_ADDRESS), burnBefore, "No stake burned for 100% on-time response");
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore, "No fee taken for 100% on-time response");
    }

    /// @notice 95% on-time response tier (2% slash) — 19 of 20 responded on-time
    function test_settleExpiredJob_95pctResponse_2pctSlash() public {
        uint256 jobId = _publishJob(0);

        // Create 20 applicants, respond to 19
        address[] memory apps = _createApplicants(20);
        bytes32[] memory appIds = new bytes32[](20);
        for (uint256 i = 0; i < 20; i++) {
            appIds[i] = _applyToJob(jobId, apps[i]);
        }
        for (uint256 i = 0; i < 19; i++) {
            _respondToApplication(appIds[i]);
        }

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        _settleExpiredJob(jobId, 20, 19, 19);

        uint256 expectedSlash = (EMPLOYER_STAKE * 200) / 10_000;
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, expectedSlash, "2% slash for 95% on-time response");
    }

    /// @notice 90% on-time response tier (5% slash) — 9 of 10 responded on-time
    function test_settleExpiredJob_90pctResponse_5pctSlash() public {
        uint256 jobId = _publishJob(0);

        address[] memory apps = _createApplicants(10);
        bytes32[] memory appIds = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            appIds[i] = _applyToJob(jobId, apps[i]);
        }
        for (uint256 i = 0; i < 9; i++) {
            _respondToApplication(appIds[i]);
        }

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        _settleExpiredJob(jobId, 10, 9, 9);

        uint256 expectedSlash = (EMPLOYER_STAKE * 500) / 10_000;
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, expectedSlash, "5% slash for 90% on-time response");
    }

    /// @notice 80% on-time response tier (10% slash) — 8 of 10 responded on-time
    function test_settleExpiredJob_80pctResponse_10pctSlash() public {
        uint256 jobId = _publishJob(0);

        address[] memory apps = _createApplicants(10);
        bytes32[] memory appIds = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            appIds[i] = _applyToJob(jobId, apps[i]);
        }
        for (uint256 i = 0; i < 8; i++) {
            _respondToApplication(appIds[i]);
        }

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        _settleExpiredJob(jobId, 10, 8, 8);

        uint256 expectedSlash = (EMPLOYER_STAKE * 1000) / 10_000;
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, expectedSlash, "10% slash for 80% on-time response");
    }

    /// @notice 70% on-time response tier (18% slash) — 7 of 10 responded on-time
    function test_settleExpiredJob_70pctResponse_18pctSlash() public {
        uint256 jobId = _publishJob(0);

        address[] memory apps = _createApplicants(10);
        bytes32[] memory appIds = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            appIds[i] = _applyToJob(jobId, apps[i]);
        }
        for (uint256 i = 0; i < 7; i++) {
            _respondToApplication(appIds[i]);
        }

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        _settleExpiredJob(jobId, 10, 7, 7);

        uint256 expectedSlash = (EMPLOYER_STAKE * 1800) / 10_000;
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, expectedSlash, "18% slash for 70% on-time response");
    }

    /// @notice 60% on-time response tier (25% slash) — 6 of 10 responded on-time
    function test_settleExpiredJob_60pctResponse_25pctSlash() public {
        uint256 jobId = _publishJob(0);

        address[] memory apps = _createApplicants(10);
        bytes32[] memory appIds = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            appIds[i] = _applyToJob(jobId, apps[i]);
        }
        for (uint256 i = 0; i < 6; i++) {
            _respondToApplication(appIds[i]);
        }

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        _settleExpiredJob(jobId, 10, 6, 6);

        uint256 expectedSlash = (EMPLOYER_STAKE * 2500) / 10_000;
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, expectedSlash, "25% slash for 60% on-time response");
    }

    /// @notice 1-49% on-time response tier (50% slash) — 1 of 10 responded on-time
    function test_settleExpiredJob_10pctResponse_50pctSlash() public {
        uint256 jobId = _publishJob(0);

        address[] memory apps = _createApplicants(10);
        bytes32[] memory appIds = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            appIds[i] = _applyToJob(jobId, apps[i]);
        }
        _respondToApplication(appIds[0]); // only 1 of 10

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        _settleExpiredJob(jobId, 10, 1, 1);

        uint256 expectedSlash = (EMPLOYER_STAKE * 5000) / 10_000;
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, expectedSlash, "50% slash for 10% on-time response");
    }

    // ============ Expired Settlement: No Applications ============

    /// @notice Settle expired job with 0 applications — 0% slash
    function test_settleExpiredJob_noApplications_noSlash() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 orgBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _settleExpiredJob(jobId);

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore, "No slash when no applicants");
        assertEq(
            _getOrgOperationalBalance(DEFAULT_ORG_ID), orgBefore, "Full stake returned; fee was deducted at creation"
        );
    }

    // ============ Expired Settlement From Published ============

    /// @notice Published job cannot be expired-settled before 365 days
    function test_settleExpiredJob_publishedJob_before365days_reverts() public {
        uint256 jobId = _publishJob(0);
        // Don't close — leave Active

        JobView memory job = jobCommitment.job(jobId);
        uint256 createdAt = job.createdAt;

        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(
                Errors.JobNotExpired.selector, createdAt, TEST_MAX_PUBLISHED_DURATION, block.timestamp
            ),
            jobId,
            0,
            0,
            0,
            _counterSnapshotRoot(0),
            executor
        );
    }

    /// @notice Published job CAN be expired-settled after 365 days (abandoned org safety valve)
    function test_settleExpiredJob_publishedJob_after365days_succeeds() public {
        uint256 jobId = _publishJob(0);
        _applyToJob(jobId, applicant1);
        // Don't close, don't respond — simulate abandoned org

        vm.warp(block.timestamp + TEST_MAX_PUBLISHED_DURATION + 1);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 jobFundsBefore = usdc.balanceOf(address(jobFunds));

        // 1 total, 0 responded, 0 on-time → 100% slash
        _settleExpiredJob(jobId, 1, 0, 0);

        // Verify job is now Closed
        JobView memory job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Closed));
        assertTrue(job.orgStakeSettled);

        // 0 on-time out of 1 total → harsh table → 100% slash
        uint256 expectedSlash = job.stake;
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, expectedSlash, "100% slash should be burnt");
        assertEq(usdc.balanceOf(address(jobFunds)), jobFundsBefore - expectedSlash, "JobFunds balance reduced by slash");
    }

    // ============ Withdrawal After ExpiredSettlement ============

    /// @notice Applicants can withdraw after expired settlement (responded or deadline passed)
    function test_withdrawAfterExpiredSettlement() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        bytes32 appId2 = _applyToJob(jobId, applicant2);

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);
        _settleExpiredJob(jobId, 2, 0, 0);

        // Warp past deadline so unresponded applicants can withdraw
        _warpPastDeadline(appId1);

        // Both can withdraw
        uint256 bal1Before = usdc.balanceOf(applicant1);
        uint256 bal2Before = usdc.balanceOf(applicant2);

        _withdrawStake(appId1, applicant1);
        _withdrawStake(appId2, applicant2);

        assertEq(usdc.balanceOf(applicant1), bal1Before + APPLICANT_STAKE);
        assertEq(usdc.balanceOf(applicant2), bal2Before + APPLICANT_STAKE);
    }

    // ============ Withdrawal After Deadline Without Response ============

    /// @notice Applicant can withdraw after deadline even if employer never responded
    function test_withdrawAfterDeadline_noResponse() public {
        uint256 jobId = _publishJob(0); // tier 0 = 3 days deadline

        bytes32 appId = _applyToJob(jobId, applicant1);

        // Not responded, not closed — but deadline passes
        ApplicationView memory app = jobCommitment.application(appId);
        vm.warp(app.responseDeadline + 1);

        uint256 balBefore = usdc.balanceOf(applicant1);
        _withdrawStake(appId, applicant1);

        assertEq(usdc.balanceOf(applicant1), balBefore + APPLICANT_STAKE);
    }

    // ============ Withdrawal With Different Fee Tiers ============

    /// @notice Withdrawal works with tier 1 (5 day deadline)
    function test_withdrawAfterDeadline_tier1() public {
        _publishJob(1); // tier 1
        bytes32 appId = _applyToJobWithParams(applicant1, APPLICANT_STAKE_96, 5);

        // 4 days — too early
        vm.warp(block.timestamp + 4 days);
        vm.prank(applicant1);
        vm.expectRevert(Errors.WithdrawalNotReady.selector);
        jobCommitment.withdrawStake(appId);

        // 6 days — should work
        vm.warp(block.timestamp + 2 days);
        _withdrawStake(appId, applicant1);
    }

    /// @notice Withdrawal works with tier 2 (7 day deadline)
    function test_withdrawAfterDeadline_tier2() public {
        _publishJob(2); // tier 2
        bytes32 appId = _applyToJobWithParams(applicant1, APPLICANT_STAKE_96, 7);

        // 6 days — too early
        vm.warp(block.timestamp + 6 days);
        vm.prank(applicant1);
        vm.expectRevert(Errors.WithdrawalNotReady.selector);
        jobCommitment.withdrawStake(appId);

        // 8 days — should work
        vm.warp(block.timestamp + 2 days);
        _withdrawStake(appId, applicant1);
    }

    // ============ Withdrawal While Paused ============

    /// @notice withdraw works even when contract is paused
    function test_withdrawWhilePaused() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);
        _respondToApplication(appId);

        // Pause contract
        vm.prank(owner);
        jobCommitment.pause();

        // Withdrawal should still work (not pause-gated)
        uint256 balBefore = usdc.balanceOf(applicant1);
        _withdrawStake(appId, applicant1);
        assertEq(usdc.balanceOf(applicant1), balBefore + APPLICANT_STAKE);
    }

    // ============ expiredSettlementInfo Edge Cases ============

    /// @notice expiredSettlementInfo for non-existent job
    function test_expiredSettlementInfo_nonExistentJob() public view {
        (bool canSettle, JobExpiryStatus status) = jobCommitment.expiredSettlementInfo(999);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(JobExpiryStatus.JobNotFound));
    }

    /// @notice expiredSettlementInfo for already closed job (orgStakeSettled checked first)
    function test_expiredSettlementInfo_closedJob() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);
        _respondToApplication(appId);
        _unpublishJob(jobId);
        _closeJob(jobId, 1, 1, 1);

        (bool canSettle, JobExpiryStatus status) = jobCommitment.expiredSettlementInfo(jobId);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(JobExpiryStatus.AlreadySettled));
    }

    /// @notice expiredSettlementInfo for closed but not expired job
    function test_expiredSettlementInfo_closedNotExpired() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);

        // Only 1 day elapsed
        vm.warp(block.timestamp + 1 days);

        (bool canSettle, JobExpiryStatus status) = jobCommitment.expiredSettlementInfo(jobId);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(JobExpiryStatus.NotYetExpired));
    }

    // ============ ExpiredSettlement: Access Control After Expiration ============

    /// @notice Non-executor cannot settle even when job IS expired
    function test_settleExpiredJob_nonExecutor_afterExpiration_reverts() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        // Owner cannot settle expired jobs
        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.NotExecutor.selector), jobId, 0, 0, 0, _counterSnapshotRoot(0), owner
        );

        // Employer cannot settle expired jobs
        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.NotExecutor.selector), jobId, 0, 0, 0, _counterSnapshotRoot(0), employer
        );

        // Random stranger cannot settle expired jobs
        address stranger = makeAddr("stranger");
        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.NotExecutor.selector), jobId, 0, 0, 0, _counterSnapshotRoot(0), stranger
        );

        // Executor can settle expired jobs.
        _settleExpiredJob(jobId);
    }

    // ============ Internal Helpers ============

    function _createApplicants(uint256 count) internal returns (address[] memory apps) {
        apps = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            apps[i] = makeAddr(string(abi.encodePacked("app", i)));
            _fundApplicant(apps[i]);
        }
    }
}
