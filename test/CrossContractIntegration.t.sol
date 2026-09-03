// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "./shared/TestBase.sol";
import {JobStatus} from "../src/types/JobTypes.sol";
import {Errors} from "../src/Errors.sol";

import {TEST_TIER_0_BASE_FEE, TEST_MIN_STAKE} from "./shared/TestBase.sol";

/// @title CrossContractIntegrationTest
/// @notice Tests full OrgRegistry + JobCommitment integration flows
contract CrossContractIntegrationTest is JobCommitmentTestBase {
    // ============ Respond by Executor ============

    function test_recordApplicationResponseByExecutor() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        _respondToApplicationAs(appId, executor);
        _assertApplicationResponded(appId);
    }

    // ============ Create Job with Insufficient Org Balance ============

    function test_publishJob_revert_insufficientOrgBalance() public {
        uint256 employer2PrivateKey = 0xE22CE;
        address employer2 = vm.addr(employer2PrivateKey);
        uint256 orgId2 = 2;
        _createOrgForEmployer(employer2, "new.com", orgId2);

        // 60 USDC is not enough for TEST_MIN_STAKE plus the configured publishing fee.
        uint256 depositAmount = 60_000_000;
        _fundOrg(orgId2, employer2PrivateKey, depositAmount);

        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobPublish(orgId2, TEST_MIN_STAKE, 0, "QmTest", employer2, keyNonce, expiry);
        uint256 fee = TEST_TIER_0_BASE_FEE + ((TEST_MIN_STAKE * 150) / 10_000);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InsufficientBalance.selector, TEST_MIN_STAKE + fee, depositAmount)
        );
        _executeJobPublishWithFee(employer2, orgId2, TEST_MIN_STAKE, 0, fee, "QmTest", keyNonce, expiry, signature);
    }

    // ============ Multiple Jobs Same Org ============

    function test_multipleJobs_sameOrg_independentLifecycles() public {
        uint256 jobId1 = _publishJob(0);
        uint256 jobId2 = _publishJob(1);

        bytes32 appId1 = _applyToJob(jobId1, applicant1);
        bytes32 appId2 = _applyToJob(jobId2, applicant2);

        _respondToApplication(appId1);
        _unpublishJob(jobId1);
        _closeJob(jobId1, 1, 1, 1);
        _assertJobStatus(jobId2, JobStatus.Published);

        _respondToApplication(appId2);
        _unpublishJob(jobId2);
        _closeJob(jobId2, 1, 1, 1);
        _assertJobStatus(jobId1, JobStatus.Closed);
        _assertJobStatus(jobId2, JobStatus.Closed);

        _withdrawStake(appId1, applicant1);
        _withdrawStake(appId2, applicant2);
    }

    // ============ Authority Handovers ============

    function test_adminRevokedMidJobLifecycle_cannotCloseJob() public {
        address replacementAdmin = makeAddr("replacementAdmin");
        uint256 jobId = _publishJob(0);

        vm.prank(employer);
        orgRegistry.setOrgAdmin(DEFAULT_ORG_ID, replacementAdmin, true);

        vm.prank(replacementAdmin);
        orgRegistry.setOrgAdmin(DEFAULT_ORG_ID, employer, false);

        uint256 revokedKeyNonce = _nextJobUnpublishKeyNonce();
        uint256 revokedExpiry = block.timestamp + 1 hours;
        bytes memory revokedSignature = _signJobUnpublish(jobId, employer, revokedKeyNonce, revokedExpiry);

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobManager.selector, DEFAULT_ORG_ID, employer));
        jobCommitment.unpublishJob(jobId, revokedKeyNonce, revokedExpiry, revokedSignature);

        _unpublishJobAs(jobId, replacementAdmin);

        assertFalse(orgRegistry.isOrgAdmin(DEFAULT_ORG_ID, employer));
        assertTrue(orgRegistry.isOrgAdmin(DEFAULT_ORG_ID, replacementAdmin));
        _assertJobStatus(jobId, JobStatus.Unpublished);
    }

    function test_treasuryRotationDoesNotBreakJobLifecycle() public {
        address newTreasury = makeAddr("newTreasury");
        uint256 jobId = _publishJob(0);

        _rotateOrgTreasury(newTreasury);

        _unpublishJob(jobId);
        _closeJob(jobId);

        uint256 withdrawAmount = 1_000_000;

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, DEFAULT_ORG_ID, employer));
        jobFunds.withdraw(DEFAULT_ORG_ID, withdrawAmount);

        uint256 newTreasuryBefore = usdc.balanceOf(newTreasury);

        vm.prank(newTreasury);
        jobFunds.withdraw(DEFAULT_ORG_ID, withdrawAmount);

        assertEq(usdc.balanceOf(newTreasury), newTreasuryBefore + withdrawAmount);
        assertEq(orgRegistry.orgTreasury(DEFAULT_ORG_ID), newTreasury);
        _assertJobStatus(jobId, JobStatus.Closed);
    }

    function test_executorRotation_afterApplicationSubmission() public {
        address newExecutor = makeAddr("newExecutor");
        uint256 jobId = _publishJob(0);
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        bytes32 appId2 = _applyToJob(jobId, applicant2);

        vm.startPrank(owner);
        jobCommitment.addExecutor(newExecutor);
        jobCommitment.removeExecutor(executor);
        vm.stopPrank();

        _respondToApplicationAs(appId1, newExecutor);

        bytes32 responseId = _generateResponseId(appId2);
        vm.prank(executor);
        vm.expectRevert(Errors.NotExecutor.selector);
        jobCommitment.recordApplicationResponse(appId2, responseId);

        _assertApplicationResponded(appId1);
        assertFalse(jobCommitment.application(appId2).isResponded);
    }

    function test_jobManagerGrantSurvivesTreasuryRotation() public {
        address jobManager = makeAddr("jobManager");
        address newTreasury = makeAddr("newTreasury");
        uint256 jobId = _publishJob(0);

        vm.prank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, jobManager, true);

        _rotateOrgTreasury(newTreasury);

        _unpublishJobAs(jobId, jobManager);
        _closeJobAs(jobId, jobManager, 0, 0, 0);

        uint256 amount = 1_000_000;
        vm.startPrank(jobManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, DEFAULT_ORG_ID, jobManager));
        jobFunds.depositWithAuthorization(DEFAULT_ORG_ID, amount, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, DEFAULT_ORG_ID, jobManager));
        jobFunds.withdraw(DEFAULT_ORG_ID, amount);
        vm.stopPrank();

        assertTrue(jobFunds.isJobManager(DEFAULT_ORG_ID, jobManager));
        assertEq(orgRegistry.orgTreasury(DEFAULT_ORG_ID), newTreasury);
        _assertJobStatus(jobId, JobStatus.Closed);
    }

    function _rotateOrgTreasury(address newTreasury) private {
        vm.prank(employer);
        orgRegistry.proposeOrgTreasuryTransfer(DEFAULT_ORG_ID, newTreasury);

        vm.prank(newTreasury);
        orgRegistry.acceptOrgTreasuryTransfer(DEFAULT_ORG_ID);

        vm.prank(employer);
        orgRegistry.finalizeOrgTreasuryTransfer(DEFAULT_ORG_ID);
    }

    function _closeJobAs(
        uint256 jobId,
        address submitter,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses
    ) private {
        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(totalApplications);
        bytes memory signature = _signJobClose(
            jobId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            submitter,
            keyNonce,
            expiry
        );

        vm.prank(submitter);
        jobCommitment.closeJob(
            jobId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            keyNonce,
            expiry,
            signature
        );
    }
}
