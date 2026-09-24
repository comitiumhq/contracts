// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {JobView} from "../../src/interfaces/IJobCommitment.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";

/// @title JobLifecycleTest
/// @notice Tests for job unpublishing, closing, and settlement.
contract JobLifecycleTest is JobCommitmentTestBase {
    // ============ Unpublish Job Tests ============

    function test_unpublishJob_success() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Unpublished));
        assertTrue(job.unpublishedAt > 0);
    }

    function test_unpublishJob_alreadyUnpublished_reverts() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, employer, keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidJobStatus.selector, JobStatus.Unpublished, JobStatus.Published)
        );
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    function test_unpublishJob_alreadyClosed_reverts() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);
        _closeJob(jobId);

        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, employer, keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidJobStatus.selector, JobStatus.Closed, JobStatus.Published));
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    function test_unpublishJob_jobNotFound_reverts() public {
        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(999, employer, keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobNotFound.selector, 999));
        jobCommitment.unpublishJob(999, keyNonce, expiry, signature);
    }

    function test_unpublishJob_expiredSignature_reverts() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, employer, keyNonce, expiry);

        vm.warp(expiry + 1);

        vm.prank(employer);
        vm.expectRevert(Errors.SignatureExpired.selector);
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    function test_unpublishJob_expiryAtCurrentTimestamp_succeeds() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp;
        bytes memory signature = _signJobUnpublish(jobId, employer, keyNonce, expiry);

        vm.prank(employer);
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);

        _assertJobStatus(jobId, JobStatus.Unpublished);
    }

    function test_unpublishJob_jobManager_succeeds() public {
        uint256 jobId = _publishJob(0);

        vm.prank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, true);

        _unpublishJobAs(jobId, applicant1);

        _assertJobStatus(jobId, JobStatus.Unpublished);
    }

    function test_unpublishJob_nonManagerWithValidSignature_reverts() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobManager.selector, DEFAULT_ORG_ID, applicant1));
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    function test_unpublishJob_revokedJobManager_reverts() public {
        uint256 jobId = _publishJob(0);

        vm.startPrank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, true);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, false);
        vm.stopPrank();

        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobManager.selector, DEFAULT_ORG_ID, applicant1));
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    function test_unpublishJob_invalidSignature_wrongSigner_reverts() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        uint256 wrongKey = 0x9999;
        bytes32 structHash = keccak256(abi.encode(JOB_UNPUBLISH_TYPEHASH, jobId, employer, keyNonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(employer);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, badSig);
    }

    function test_unpublishJob_mismatchedUnpublisher_reverts() public {
        uint256 jobId = _publishJob(0);

        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, employer, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    function test_unpublishJob_wrongNonceScope_reverts() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _packKeyNonce(NONCE_SCOPE_JOB_CLOSE, 1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, employer, keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidNonceScope.selector, NONCE_SCOPE_JOB_CLOSE, NONCE_SCOPE_JOB_UNPUBLISH)
        );
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    function test_unpublishJob_noReplayNeeded_sameJobUnpublishesTwiceFails() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, employer, keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidJobStatus.selector, JobStatus.Unpublished, JobStatus.Published)
        );
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    // ============ Close Job Tests ============

    function test_closeJob_fromPublished_success() public {
        uint256 jobId = _publishJob(0);

        _closeJob(jobId);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Closed));
        assertEq(job.unpublishedAt, 0);
        assertTrue(job.orgStakeSettled);
    }

    function test_closeJob_success_zeroCounters() public {
        uint256 jobId = _publishJob(0);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _closeJob(jobId);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Closed));
        assertTrue(job.orgStakeSettled);

        uint256 orgOpBalAfter = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        assertEq(orgOpBalAfter, orgOpBalBefore);
    }

    function test_closeJob_nonZeroCountersRequireSnapshotRoot() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 1, 1, 1, bytes32(0), keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(Errors.CounterSnapshotRootRequired.selector);
        jobCommitment.closeJob(jobId, 1, 1, 1, bytes32(0), keyNonce, expiry, sig);
    }

    function test_closeJob_allOnTime_noSlash() public {
        uint256 jobId = _publishJob(0);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _unpublishJob(jobId);
        _closeJob(jobId, 2, 2, 2);

        uint256 orgOpBalAfter = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        assertEq(orgOpBalAfter, orgOpBalBefore);
    }

    function test_closeJob_callerBoundSignature_succeeds() public {
        uint256 jobId = _publishJob(0);
        address caller = makeAddr("closeCaller");

        vm.prank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, caller, true);
        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory signature = _signJobClose(jobId, 0, 0, 0, counterSnapshotRoot, caller, keyNonce, expiry);

        vm.prank(caller);
        jobCommitment.closeJob(jobId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry, signature);

        _assertJobStatus(jobId, JobStatus.Closed);
    }

    function test_closeJob_jobManager_succeeds() public {
        uint256 jobId = _publishJob(0);

        vm.prank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, true);
        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory signature = _signJobClose(jobId, 0, 0, 0, counterSnapshotRoot, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        jobCommitment.closeJob(jobId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry, signature);

        _assertJobStatus(jobId, JobStatus.Closed);
    }

    function test_closeJob_nonManagerWithValidSignature_reverts() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory signature = _signJobClose(jobId, 0, 0, 0, counterSnapshotRoot, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobManager.selector, DEFAULT_ORG_ID, applicant1));
        jobCommitment.closeJob(jobId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry, signature);
    }

    function test_closeJob_revokedJobManager_reverts() public {
        uint256 jobId = _publishJob(0);

        vm.startPrank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, true);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, false);
        vm.stopPrank();
        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory signature = _signJobClose(jobId, 0, 0, 0, counterSnapshotRoot, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobManager.selector, DEFAULT_ORG_ID, applicant1));
        jobCommitment.closeJob(jobId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry, signature);
    }

    function test_closeJob_70percentOnTime_usesSoftSlash() public {
        uint256 jobId = _publishJob(0);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _unpublishJob(jobId);
        _closeJob(jobId, 10, 10, 7);

        uint256 expectedSlash = (EMPLOYER_STAKE * 1200) / 10_000;

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - expectedSlash);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_closeJob_allLateAllResponded_30pctSoftSlash() public {
        uint256 jobId = _publishJob(0);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _unpublishJob(jobId);
        _closeJob(jobId, 2, 2, 0);

        uint256 expectedSlash = (EMPLOYER_STAKE * 3000) / 10_000;

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - expectedSlash);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_closeJob_notAllResponded_reverts() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 2, 1, 1, _counterSnapshotRoot(2), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAllResponded.selector, 1, 2));
        jobCommitment.closeJob(jobId, 2, 1, 1, _counterSnapshotRoot(2), keyNonce, expiry, sig);
    }

    function test_closeJob_fromUnpublishedStatus_success() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        _closeJob(jobId);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Closed));
    }

    function test_closeJob_jobNotFound_reverts() public {
        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(999, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobNotFound.selector, 999));
        jobCommitment.closeJob(999, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }

    function test_closeJob_alreadyClosed_reverts() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);
        _closeJob(jobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobAlreadyClosed.selector, jobId));
        jobCommitment.closeJob(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }

    function test_closeJob_nonceReplay_reverts() public {
        uint256 jobId1 = _publishJob(0);
        uint256 jobId2 = _publishJob(0);
        _unpublishJob(jobId1);
        _unpublishJob(jobId2);

        uint256 usedKeyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig1 = _signJobClose(jobId1, 0, 0, 0, _counterSnapshotRoot(0), usedKeyNonce, expiry);
        vm.prank(employer);
        jobCommitment.closeJob(jobId1, 0, 0, 0, _counterSnapshotRoot(0), usedKeyNonce, expiry, sig1);

        bytes memory sig2 = _signJobClose(jobId2, 0, 0, 0, _counterSnapshotRoot(0), usedKeyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("InvalidAccountNonce(address,uint256)", operator, usedKeyNonce + 1));
        jobCommitment.closeJob(jobId2, 0, 0, 0, _counterSnapshotRoot(0), usedKeyNonce, expiry, sig2);
    }

    function test_closeJob_wrongNonceScope_reverts() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        uint256 keyNonce = _packKeyNonce(NONCE_SCOPE_JOB_PUBLISH, 1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidNonceScope.selector, NONCE_SCOPE_JOB_PUBLISH, NONCE_SCOPE_JOB_CLOSE)
        );
        jobCommitment.closeJob(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }

    function test_closeJob_wrongCloser_reverts() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 0, 0, 0, _counterSnapshotRoot(0), applicant1, keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.closeJob(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }

    // ============ Counter Invariant Validation ============

    function test_closeJob_onTimeExceedsResponded_reverts() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 2, 2, 3, _counterSnapshotRoot(2), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCounters.selector, 2, 2, 3));
        jobCommitment.closeJob(jobId, 2, 2, 3, _counterSnapshotRoot(2), keyNonce, expiry, sig);
    }

    function test_closeJob_respondedExceedsTotal_reverts() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 3, 5, 2, _counterSnapshotRoot(3), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCounters.selector, 3, 5, 2));
        jobCommitment.closeJob(jobId, 3, 5, 2, _counterSnapshotRoot(3), keyNonce, expiry, sig);
    }

    function test_closeJob_expired_reverts() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);

        vm.warp(expiry + 1);

        vm.prank(employer);
        vm.expectRevert(Errors.SignatureExpired.selector);
        jobCommitment.closeJob(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }
}
