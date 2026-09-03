// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {IJobCommitment} from "../../src/interfaces/IJobCommitment.sol";
import {Errors} from "../../src/Errors.sol";

/// @title JobContentURIUpdateTest
/// @notice Full revert matrix, event, and freshness coverage for updateJobContentURI (open-job metadata edits).
contract JobContentURIUpdateTest is JobCommitmentTestBase {
    function test_updateJobContentURI_emitsEvent() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobContentURIUpdate(jobId, "ipfs://job-v2", employer, keyNonce, expiry);

        vm.expectEmit(true, true, true, true, address(jobCommitment));
        emit IJobCommitment.JobContentURIUpdated(jobId, DEFAULT_ORG_ID, employer, "ipfs://job-v2");

        vm.prank(employer);
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v2", keyNonce, expiry, sig);

        assertEq(jobCommitment.job(jobId).contentURI, "ipfs://job-v2");
    }

    function test_updateJobContentURI_revertsForEmptyURI() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobContentURIUpdate(jobId, "", employer, keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(Errors.EmptyContentURI.selector);
        jobCommitment.updateJobContentURI(jobId, "", keyNonce, expiry, sig);
    }

    function test_updateJobContentURI_revertsForNonExistentJob() public {
        uint256 bogusJobId = 999_999;
        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobContentURIUpdate(bogusJobId, "ipfs://x", employer, keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobNotFound.selector, bogusJobId));
        jobCommitment.updateJobContentURI(bogusJobId, "ipfs://x", keyNonce, expiry, sig);
    }

    function test_updateJobContentURI_revertsForExpiredSignature() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp - 1;
        bytes memory sig = _signJobContentURIUpdate(jobId, "ipfs://job-v2", employer, keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(Errors.SignatureExpired.selector);
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v2", keyNonce, expiry, sig);
    }

    function test_updateJobContentURI_revertsForWrongUpdater() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        // Signature binds updater = employer, but applicant1 submits it, so the recovered actor mismatches
        // the signed struct and signature verification fails before the manager check.
        bytes memory sig = _signJobContentURIUpdate(jobId, "ipfs://job-v2", employer, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v2", keyNonce, expiry, sig);
    }

    function test_updateJobContentURI_nonceReplay_reverts() public {
        uint256 jobId = _publishJob(0);
        uint256 usedKeyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        bytes memory sig1 = _signJobContentURIUpdate(jobId, "ipfs://job-v2", employer, usedKeyNonce, expiry);
        vm.prank(employer);
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v2", usedKeyNonce, expiry, sig1);

        bytes memory sig2 = _signJobContentURIUpdate(jobId, "ipfs://job-v3", employer, usedKeyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("InvalidAccountNonce(address,uint256)", operator, usedKeyNonce + 1));
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v3", usedKeyNonce, expiry, sig2);
    }

    function test_updateJobContentURI_revertsWhenPaused() public {
        uint256 jobId = _publishJob(0);
        uint256 keyNonce = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobContentURIUpdate(jobId, "ipfs://job-v2", employer, keyNonce, expiry);

        vm.prank(owner);
        jobCommitment.pause();

        vm.prank(employer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v2", keyNonce, expiry, sig);
    }

    function test_updateJobContentURI_freshness_secondUpdateReplacesFirst() public {
        uint256 jobId = _publishJob(0);

        uint256 keyNonce1 = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry1 = block.timestamp + 1 hours;
        bytes memory sig1 = _signJobContentURIUpdate(jobId, "ipfs://job-v2", employer, keyNonce1, expiry1);
        vm.prank(employer);
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v2", keyNonce1, expiry1, sig1);
        assertEq(jobCommitment.job(jobId).contentURI, "ipfs://job-v2");

        uint256 keyNonce2 = _nextJobContentURIUpdateKeyNonce();
        uint256 expiry2 = block.timestamp + 1 hours;
        bytes memory sig2 = _signJobContentURIUpdate(jobId, "ipfs://job-v3", employer, keyNonce2, expiry2);
        vm.prank(employer);
        jobCommitment.updateJobContentURI(jobId, "ipfs://job-v3", keyNonce2, expiry2, sig2);
        assertEq(jobCommitment.job(jobId).contentURI, "ipfs://job-v3");
    }
}
