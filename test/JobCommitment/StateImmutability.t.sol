// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {
    JobCommitmentTestBase,
    TEST_MAX_PUBLISHED_DURATION,
    TEST_MAX_UNPUBLISHED_DURATION
} from "../shared/TestBase.sol";
import {ApplicationView, JobView} from "../../src/interfaces/IJobCommitment.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";

contract StateImmutabilityTest is JobCommitmentTestBase {
    function testFuzz_applicationFields_immutableAfterRespond(uint8 numApps) public {
        numApps = uint8(bound(numApps, 1, 5));
        _publishJob(0);

        bytes32[] memory appIds = new bytes32[](numApps);
        for (uint8 i = 0; i < numApps; i++) {
            address app = makeAddr(string(abi.encodePacked("immut", i)));
            _fundApplicant(app);
            appIds[i] = _applyToJob(app);
        }

        for (uint8 i = 0; i < numApps; i++) {
            ApplicationView memory before = jobCommitment.application(appIds[i]);
            assertFalse(before.isResponded, "Should be false before respond");

            _respondToApplication(appIds[i]);

            ApplicationView memory after_ = jobCommitment.application(appIds[i]);
            assertTrue(after_.isResponded, "Should be true after respond");

            // Fields that must NOT change
            assertEq(after_.applicant, before.applicant, "applicant must not change");
            assertEq(after_.stake, before.stake, "stake must not change");
            assertEq(after_.appliedAt, before.appliedAt, "appliedAt must not change");
            assertEq(after_.responseDeadline, before.responseDeadline, "responseDeadline must not change");
        }
    }

    function test_jobTimestamps_statusConsistency() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(applicant1);

        // Published: both timestamps are unset.
        JobView memory j = jobCommitment.job(jobId);
        assertEq(j.unpublishedAt, 0, "unpublishedAt must be 0 when Published");
        assertEq(j.closedAt, 0, "closedAt must be 0 when Published");

        _respondToApplication(appId);
        _unpublishJob(jobId);

        // Unpublished: only the intake boundary is recorded.
        j = jobCommitment.job(jobId);
        assertGt(j.unpublishedAt, 0, "unpublishedAt must be set when Unpublished");
        assertEq(j.closedAt, 0, "closedAt must be 0 when Unpublished");

        uint256 unpublishedAtBefore = j.unpublishedAt;
        _closeJob(jobId, 1, 1, 1);

        // Closed: both timestamps are set and the unpublish boundary is immutable.
        j = jobCommitment.job(jobId);
        assertGt(j.unpublishedAt, 0, "unpublishedAt must remain set when Closed");
        assertGt(j.closedAt, 0, "closedAt must be set when Closed");
        assertEq(j.unpublishedAt, unpublishedAtBefore, "unpublishedAt must not change after close");
    }

    function test_normalClose_recordsDistinctLifecycleTimestamps() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(applicant1);
        _respondToApplication(appId);

        _unpublishJob(jobId);
        vm.warp(block.timestamp + 1);
        _closeJob(jobId, 1, 1, 1);

        JobView memory j = jobCommitment.job(jobId);
        assertGt(j.unpublishedAt, 0, "unpublishedAt must be set");
        assertGt(j.closedAt, j.unpublishedAt, "closedAt must follow unpublishedAt");
    }

    function test_normalCloseFromPublished_leavesUnpublishedTimestampUnset() public {
        uint256 jobId = _publishJob(0);

        _closeJob(jobId);

        JobView memory j = jobCommitment.job(jobId);
        assertEq(j.unpublishedAt, 0, "direct close must not fabricate an unpublish boundary");
        assertGt(j.closedAt, 0, "closedAt must be set");
    }

    function test_expiredSettlementFromPublished_recordsBothTimestamps() public {
        uint256 jobId = _publishJob(0);

        vm.warp(block.timestamp + TEST_MAX_PUBLISHED_DURATION + 1);
        _settleExpiredJob(jobId);

        JobView memory j = jobCommitment.job(jobId);
        assertEq(uint8(j.status), uint8(JobStatus.Closed));
        assertGt(j.unpublishedAt, 0, "expired settlement must record unpublish");
        assertGt(j.closedAt, 0, "expired settlement must record close");
        assertEq(j.unpublishedAt, j.closedAt, "forced unpublish and close share the settlement timestamp");
    }

    function test_orgStakeSettled_iffClosed() public {
        uint256 jobId = _publishJob(0);

        // Published
        JobView memory j = jobCommitment.job(jobId);
        assertFalse(j.orgStakeSettled, "orgStakeSettled must be false when Published");

        bytes32 appId = _applyToJob(applicant1);
        _respondToApplication(appId);
        _unpublishJob(jobId);

        // Unpublished
        j = jobCommitment.job(jobId);
        assertFalse(j.orgStakeSettled, "orgStakeSettled must be false when Unpublished");

        _closeJob(jobId, 1, 1, 1);

        // Closed
        j = jobCommitment.job(jobId);
        assertTrue(j.orgStakeSettled, "orgStakeSettled must be true when Closed");
    }

    function test_unpublishedAt_immutable_settleExpiredJob() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(applicant1);
        _respondToApplication(appId);
        _unpublishJob(jobId);

        JobView memory j = jobCommitment.job(jobId);
        uint256 unpublishedAtFirst = j.unpublishedAt;
        assertGt(unpublishedAtFirst, 0, "unpublishedAt must be set after unpublish");

        // Expired settlement preserves the original unpublish boundary.
        vm.warp(j.unpublishedAt + TEST_MAX_UNPUBLISHED_DURATION + 1);
        _settleExpiredJob(jobId, 1, 1, 1);

        j = jobCommitment.job(jobId);
        assertEq(j.unpublishedAt, unpublishedAtFirst, "unpublishedAt must not change after expired settlement");
    }
}
