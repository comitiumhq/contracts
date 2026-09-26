// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {
    JobCommitmentTestBase,
    TEST_TIER_0_BASE_FEE,
    TEST_FEE_TIER_0,
    TEST_DEADLINE_DAYS_TIER_0,
    TEST_MAX_PUBLISHED_DURATION,
    TEST_MAX_UNPUBLISHED_DURATION
} from "../shared/TestBase.sol";
import {IJobCommitment, JobView} from "../../src/interfaces/IJobCommitment.sol";

/// @title LifecycleEventsTest
/// @notice Asserts canonical lifecycle event payloads.
contract LifecycleEventsTest is JobCommitmentTestBase {
    function test_jobPublished_emitsFullPayload() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest123"), employer, keyNonce, expiry);

        uint256 expectedFee = TEST_TIER_0_BASE_FEE + (EMPLOYER_STAKE * TEST_FEE_TIER_0) / 10000;

        // jobId (topic1) is contract-assigned, so it is not checked; everything else is.
        vm.expectEmit(false, true, true, true, address(jobCommitment));
        emit IJobCommitment.JobPublished(
            0,
            DEFAULT_ORG_ID,
            employer,
            1,
            EMPLOYER_STAKE,
            expectedFee,
            TEST_DEADLINE_DAYS_TIER_0,
            keccak256("QmTest123")
        );

        _executeJobPublish(employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest123"), keyNonce, expiry, sig);
    }

    function test_jobUnpublished_emitsFullPayload() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobUnpublish(jobId, employer, keyNonce, expiry);

        vm.expectEmit(true, true, true, true, address(jobCommitment));
        emit IJobCommitment.JobUnpublished(jobId, DEFAULT_ORG_ID, employer);

        vm.prank(employer);
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, sig);
    }

    function test_applicationSubmitted_emitsFullPayload() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint8 deadlineDays = DEFAULT_RESPONSE_DEADLINE_DAYS;
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signApplication(applicationId, applicant1, deadlineDays, expiry);

        uint256 expectedResponseDeadline = block.timestamp + uint256(deadlineDays) * 1 days;

        vm.expectEmit(true, true, false, true, address(jobCommitment));
        emit IJobCommitment.ApplicationSubmitted(
            applicationId,
            applicant1,
            expectedResponseDeadline,
            keccak256(abi.encodeCall(jobCommitment.submitApplication, (applicationId, deadlineDays, expiry, sig)))
        );

        vm.prank(applicant1);
        jobCommitment.submitApplication(applicationId, deadlineDays, expiry, sig);
    }

    function test_applicationSubmitted_forwardedHashesCanonicalCalldata() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint8 deadlineDays = DEFAULT_RESPONSE_DEADLINE_DAYS;
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signApplication(applicationId, applicant1, deadlineDays, expiry);
        bytes memory callData =
            abi.encodeCall(jobCommitment.submitApplication, (applicationId, deadlineDays, expiry, sig));
        uint256 expectedResponseDeadline = block.timestamp + uint256(deadlineDays) * 1 days;

        vm.expectEmit(true, true, false, true, address(jobCommitment));
        emit IJobCommitment.ApplicationSubmitted(
            applicationId, applicant1, expectedResponseDeadline, keccak256(callData)
        );

        _forwardAs(applicant1, address(jobCommitment), callData);
    }

    function test_jobClosed_emitsCountersAndConservedStake() public {
        uint256 jobId = _publishJob(0);
        uint256 stake = jobCommitment.job(jobId).stake;

        vm.recordLogs();
        _closeJob(jobId, 0, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic0 =
            keccak256("JobClosed(uint256,uint256,address,uint32,uint32,uint32,bytes32,uint256,uint256,uint256)");

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic0) continue;
            found = true;

            assertEq(uint256(logs[i].topics[1]), jobId, "JobClosed jobId");
            assertEq(uint256(logs[i].topics[2]), DEFAULT_ORG_ID, "JobClosed orgId");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), employer, "JobClosed actor");

            (uint32 total, uint32 responded, uint32 onTime,,, uint256 stakeReturned, uint256 stakeSlashed) =
                abi.decode(logs[i].data, (uint32, uint32, uint32, bytes32, uint256, uint256, uint256));

            assertEq(total, 0, "total");
            assertEq(responded, 0, "responded");
            assertEq(onTime, 0, "onTime");
            assertEq(stakeReturned + stakeSlashed, stake, "JobClosed must conserve stake");
        }

        assertTrue(found, "JobClosed event not emitted");
    }

    function test_expiredSettlementFromPublished_emitsUnpublishedThenExpired() public {
        uint256 jobId = _publishJob(0);
        vm.warp(block.timestamp + TEST_MAX_PUBLISHED_DURATION + 1);

        vm.recordLogs();
        _settleExpiredJob(jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 unpublishedTopic = keccak256("JobUnpublished(uint256,uint256,address)");
        bytes32 expiredTopic = keccak256(
            "JobExpiredSettled(uint256,uint256,address,uint32,uint32,uint32,bytes32,uint256,uint256,uint256)"
        );
        (uint256 unpublishedIndex, bool foundUnpublished) = _findEvent(logs, unpublishedTopic);
        (uint256 expiredIndex, bool foundExpired) = _findEvent(logs, expiredTopic);

        assertTrue(foundUnpublished, "JobUnpublished event not emitted");
        assertTrue(foundExpired, "JobExpiredSettled event not emitted");
        assertLt(unpublishedIndex, expiredIndex, "JobUnpublished must precede JobExpiredSettled");
    }

    function test_expiredSettlementFromUnpublished_doesNotEmitUnpublishedAgain() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        JobView memory job = jobCommitment.job(jobId);
        vm.warp(job.unpublishedAt + TEST_MAX_UNPUBLISHED_DURATION + 1);

        vm.recordLogs();
        _settleExpiredJob(jobId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 unpublishedTopic = keccak256("JobUnpublished(uint256,uint256,address)");
        (, bool foundUnpublished) = _findEvent(logs, unpublishedTopic);

        assertFalse(foundUnpublished, "JobUnpublished emitted twice");
    }

    function _findEvent(Vm.Log[] memory logs, bytes32 topic) private pure returns (uint256 index, bool found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) return (i, true);
        }

        return (0, false);
    }
}
