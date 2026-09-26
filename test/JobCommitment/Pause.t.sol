// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase, TEST_MAX_UNPUBLISHED_DURATION} from "../shared/TestBase.sol";

/// @title PauseTest
/// @notice Tests for pause/unpause functionality
contract PauseTest is JobCommitmentTestBase {
    // ============ Pause State Blocking Tests ============

    function test_pause_publishJob_reverts() public {
        vm.prank(owner);
        jobCommitment.pause();

        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, signature
        );
    }

    function test_pause_submitApplication_reverts() public {
        vm.prank(owner);
        jobCommitment.pause();

        bytes32 applicationId = keccak256("testAppId");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signApplication(applicationId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        jobCommitment.submitApplication(applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, sig);
    }

    function test_pause_recordApplicationResponse_allowed() public {
        bytes32 appId = _submitApplication(applicant1);

        vm.prank(owner);
        jobCommitment.pause();

        _respondToApplication(appId);
        _assertApplicationResponded(appId);
    }

    function test_pause_unpublishJob_reverts() public {
        uint256 jobId = _publishJob(0);

        vm.prank(owner);
        jobCommitment.pause();

        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, employer, keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    // ============ Critical Operations Allowed When Paused ============

    function test_pause_closeJob_allowed() public {
        uint256 jobId = _publishJob(0);
        uint256 availableBefore = _getOrgAvailableBalance(DEFAULT_ORG_ID);

        vm.prank(owner);
        jobCommitment.pause();

        _closeJob(jobId);

        assertTrue(jobCommitment.job(jobId).orgStakeSettled);
        assertEq(_getOrgAvailableBalance(DEFAULT_ORG_ID), availableBefore + EMPLOYER_STAKE);
    }

    function test_pause_settleExpiredJob_allowed() public {
        uint256 jobId = _publishJob(0);
        uint256 availableBefore = _getOrgAvailableBalance(DEFAULT_ORG_ID);

        _unpublishJob(jobId);

        vm.prank(owner);
        jobCommitment.pause();

        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        _settleExpiredJob(jobId);

        assertTrue(jobCommitment.job(jobId).orgStakeSettled);
        assertEq(_getOrgAvailableBalance(DEFAULT_ORG_ID), availableBefore + EMPLOYER_STAKE);
    }

    // ============ Pause/Unpause Control Tests ============

    function test_pause_unpause() public {
        vm.prank(owner);
        jobCommitment.pause();

        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, signature
        );

        vm.prank(owner);
        jobCommitment.unpause();

        uint256 jobId = _publishJobWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"));
        assertEq(jobId, 1);
    }

    function test_pause_onlyOwner() public {
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        jobCommitment.pause();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        jobCommitment.pause();

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", applicant1));
        jobCommitment.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        jobCommitment.pause();

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        jobCommitment.unpause();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        jobCommitment.unpause();
    }
}
