// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {JobView} from "../../src/interfaces/IJobCommitment.sol";
import {JobExpiryStatus, JobStatus} from "../../src/types/JobTypes.sol";
import {TEST_MIN_STAKE, TEST_MAX_UNPUBLISHED_DURATION, TEST_MAX_PUBLISHED_DURATION} from "../shared/TestBase.sol";

/// @title PropertyFuzzTest
/// @notice Property-based fuzz tests for cross-contract accounting and state properties.
contract PropertyFuzzTest is JobCommitmentTestBase {
    // ============ E2E Accounting Conservation ============

    /// @notice Full lifecycle: all funds accounted for (fee + slash + return + applicant refunds)
    function testFuzz_e2e_accounting_closeJob(uint256 stake, uint8 feeTier) public {
        stake = bound(stake, TEST_MIN_STAKE, 1_000_000_000_000); // up to 1M USDC
        feeTier = uint8(bound(feeTier, 0, 2));

        _fundOrg(DEFAULT_ORG_ID, employerPrivateKey, stake * 3);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        // Create job
        uint256 jobId = _publishJobWithParams(DEFAULT_ORG_ID, stake, feeTier, "QmAcc");

        // Read fee from created job
        JobView memory job = jobCommitment.job(jobId);
        uint256 fee = job.feeAmount;

        // Apply with 2 applicants
        address app1 = makeAddr("accApp1");
        address app2 = makeAddr("accApp2");
        _fundApplicantWithAmount(app1, APPLICANT_STAKE * 2);
        _fundApplicantWithAmount(app2, APPLICANT_STAKE * 2);
        bytes32 appId1 = _applyToJobWithStake(app1, APPLICANT_STAKE);
        bytes32 appId2 = _applyToJobWithStake(app2, APPLICANT_STAKE);

        // Respond to all and close.
        _respondToApplication(appId1);
        _respondToApplication(appId2);
        _unpublishJob(jobId);
        _closeJob(jobId, 2, 2, 2);

        // Withdraw applicant stakes
        _withdrawStake(appId1, app1);
        _withdrawStake(appId2, app2);

        // Verify: applicants got full stakes back
        assertEq(usdc.balanceOf(app1), APPLICANT_STAKE * 2, "App1 should get full stake back");
        assertEq(usdc.balanceOf(app2), APPLICANT_STAKE * 2, "App2 should get full stake back");

        // Verify: protocol fee recipient gained exactly the fee (0% slash for 100% on-time response)
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore + fee, "Fee recipient must receive exactly fee");

        // Verify: org got stake back (fee was already deducted at creation)
        assertEq(
            _getOrgOperationalBalance(DEFAULT_ORG_ID),
            orgOpBalBefore - fee, // only lost the fee
            "Org should get full stake back minus fee"
        );
    }

    /// @notice Settle expired job with partial response: funds conservation
    function testFuzz_e2e_accounting_settleExpiredJob(uint256 stake, uint8 numApplicants, uint8 numResponded) public {
        stake = bound(stake, TEST_MIN_STAKE, 1_000_000_000_000);
        numApplicants = uint8(bound(numApplicants, 1, 5));
        numResponded = uint8(bound(numResponded, 0, numApplicants));

        _fundOrg(DEFAULT_ORG_ID, employerPrivateKey, stake * 3);

        uint256 jobId = _publishJobWithParams(DEFAULT_ORG_ID, stake, 0, "QmForce");

        // Apply
        address[] memory applicants = new address[](numApplicants);
        bytes32[] memory appIds = new bytes32[](numApplicants);
        for (uint8 i = 0; i < numApplicants; i++) {
            applicants[i] = makeAddr(string(abi.encodePacked("fc", i)));
            _fundApplicantWithAmount(applicants[i], APPLICANT_STAKE * 2);
            appIds[i] = _applyToJobWithStake(applicants[i], APPLICANT_STAKE);
        }

        // Respond to some
        for (uint8 i = 0; i < numResponded; i++) {
            _respondToApplication(appIds[i]);
        }

        // Close and settle after expiration (on-time = responded since all responses are immediate)
        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);
        uint32 numApplicants32 = _toUint32(numApplicants);
        uint32 numResponded32 = _toUint32(numResponded);
        _settleExpiredJob(jobId, numApplicants32, numResponded32, numResponded32);

        // Withdraw all applicant stakes
        for (uint8 i = 0; i < numApplicants; i++) {
            if (i >= numResponded) _warpPastDeadline(appIds[i]);
            _withdrawStake(appIds[i], applicants[i]);
            assertEq(usdc.balanceOf(applicants[i]), APPLICANT_STAKE * 2, "Applicant must get full stake back");
        }
    }

    // ============ State Machine: No Backward Transitions ============

    /// @notice Closed jobs cannot be re-closed or closed again
    function test_closedJob_noBackwardTransition() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);
        _respondToApplication(appId);
        _unpublishJob(jobId);
        _closeJob(jobId, 1, 1, 1);

        _assertJobStatus(jobId, JobStatus.Closed);

        // Cannot close closed job
        {
            uint256 closeKeyNonce = _nextJobUnpublishKeyNonce();
            uint256 closeExpiry = block.timestamp + 1 hours;
            bytes memory closeSig = _signJobUnpublish(jobId, employer, closeKeyNonce, closeExpiry);
            vm.prank(employer);
            vm.expectRevert(
                abi.encodeWithSelector(Errors.InvalidJobStatus.selector, JobStatus.Closed, JobStatus.Published)
            );
            jobCommitment.unpublishJob(jobId, closeKeyNonce, closeExpiry, closeSig);
        }

        // Cannot close again.
        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobAlreadyClosed.selector, jobId));
        jobCommitment.closeJob(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }

    // ============ expiredSettlementInfo Consistency ============

    /// @notice expiredSettlementInfo must return false for Published jobs before 365 days
    function test_expiredSettlementInfo_publishedJob_notExpired_returnsFalse() public {
        uint256 jobId = _publishJob(0);
        _applyToJob(jobId, applicant1);

        vm.warp(block.timestamp + TEST_MAX_PUBLISHED_DURATION / 2);

        (bool canSettle, JobExpiryStatus status) = jobCommitment.expiredSettlementInfo(jobId);

        assertFalse(canSettle, "Published job must not be expired-settleable before max published duration");
        assertEq(uint8(status), uint8(JobExpiryStatus.NotYetExpired));
    }

    /// @notice expiredSettlementInfo for closed expired job should match actual execution
    function test_expiredSettlementInfo_closedExpired_matchesExecution() public {
        uint256 jobId = _publishJob(0);
        _applyToJob(jobId, applicant1);
        _unpublishJob(jobId);

        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        (bool canSettle,) = jobCommitment.expiredSettlementInfo(jobId);
        assertTrue(canSettle, "Should be expired-settleable");

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 orgBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        // Expired settlement: 1 total, 0 responded, 0 on-time -> 100% slash.
        _settleExpiredJob(jobId, 1, 0, 0);

        uint256 slashAmount = EMPLOYER_STAKE; // 100% slash for 0% on-time response
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, slashAmount, "Slash mismatch");
        assertEq(orgBefore - _getOrgOperationalBalance(DEFAULT_ORG_ID), slashAmount, "OpBal deduction mismatch");
    }
}
