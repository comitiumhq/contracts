// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "./shared/TestBase.sol";
import {CommitmentStatus} from "../src/types/CommitmentTypes.sol";
import {Errors} from "../src/Errors.sol";

import {TEST_TIER_0_BASE_FEE, TEST_MIN_STAKE} from "./shared/TestBase.sol";

/// @title CrossContractIntegrationTest
/// @notice Tests full OrgRegistry + ResponseCommitment integration flows
contract CrossContractIntegrationTest is ResponseCommitmentTestBase {
    // ============ Respond by Executor ============

    function test_recordApplicationResponseByExecutor() public {
        bytes32 appId = _submitApplication(applicant1);

        _respondToApplicationAs(appId, executor);
        _assertApplicationResponded(appId);
    }

    // ============ Create Commitment with Insufficient Org Balance ============

    function test_activateCommitment_revert_insufficientOrgBalance() public {
        uint256 employer2PrivateKey = 0xE22CE;
        address employer2 = vm.addr(employer2PrivateKey);
        uint256 orgId2 = 2;
        _createOrgForEmployer(employer2, "new.com", orgId2);

        // 60 USDC is not enough for TEST_MIN_STAKE plus the configured activation fee.
        uint256 depositAmount = 60_000_000;
        _fundOrg(orgId2, employer2PrivateKey, depositAmount);

        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signCommitmentActivation(orgId2, TEST_MIN_STAKE, 0, keccak256("QmTest"), employer2, keyNonce, expiry);
        uint256 fee = TEST_TIER_0_BASE_FEE + ((TEST_MIN_STAKE * 150) / 10_000);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InsufficientBalance.selector, TEST_MIN_STAKE + fee, depositAmount)
        );
        _executeCommitmentActivationWithFee(
            employer2, orgId2, TEST_MIN_STAKE, 0, fee, keccak256("QmTest"), keyNonce, expiry, signature
        );
    }

    // ============ Multiple Commitments Same Org ============

    function test_multipleCommitments_sameOrg_independentLifecycles() public {
        uint256 commitmentId1 = _activateCommitment(0);
        uint256 commitmentId2 = _activateCommitment(1);

        _stopCommitment(commitmentId1);
        _settleCommitment(commitmentId1);
        _assertCommitmentStatus(commitmentId2, CommitmentStatus.Active);

        _stopCommitment(commitmentId2);
        _settleCommitment(commitmentId2);
        _assertCommitmentStatus(commitmentId1, CommitmentStatus.Settled);
        _assertCommitmentStatus(commitmentId2, CommitmentStatus.Settled);
    }

    // ============ Authority Handovers ============

    function test_adminRevokedMidCommitmentLifecycle_cannotSettleCommitment() public {
        address replacementAdmin = makeAddr("replacementAdmin");
        uint256 commitmentId = _activateCommitment(0);

        vm.prank(employer);
        orgRegistry.setOrgAdmin(DEFAULT_ORG_ID, replacementAdmin, true);

        vm.prank(replacementAdmin);
        orgRegistry.setOrgAdmin(DEFAULT_ORG_ID, employer, false);

        uint256 revokedKeyNonce = _nextCommitmentStopKeyNonce();
        uint256 revokedExpiry = block.timestamp + 1 hours;
        bytes memory revokedSignature = _signCommitmentStop(commitmentId, employer, revokedKeyNonce, revokedExpiry);

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotCommitmentManager.selector, DEFAULT_ORG_ID, employer));
        responseCommitment.stopCommitment(commitmentId, revokedKeyNonce, revokedExpiry, revokedSignature);

        _stopCommitmentAs(commitmentId, replacementAdmin);

        assertFalse(orgRegistry.isOrgAdmin(DEFAULT_ORG_ID, employer));
        assertTrue(orgRegistry.isOrgAdmin(DEFAULT_ORG_ID, replacementAdmin));
        _assertCommitmentStatus(commitmentId, CommitmentStatus.Stopped);
    }

    function test_treasuryRotationDoesNotBreakCommitmentLifecycle() public {
        address newTreasury = makeAddr("newTreasury");
        uint256 commitmentId = _activateCommitment(0);

        _rotateOrgTreasury(newTreasury);

        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId);

        uint256 withdrawAmount = 1_000_000;

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, DEFAULT_ORG_ID, employer));
        commitmentFunds.withdraw(DEFAULT_ORG_ID, withdrawAmount);

        uint256 newTreasuryBefore = usdc.balanceOf(newTreasury);

        vm.prank(newTreasury);
        commitmentFunds.withdraw(DEFAULT_ORG_ID, withdrawAmount);

        assertEq(usdc.balanceOf(newTreasury), newTreasuryBefore + withdrawAmount);
        assertEq(orgRegistry.orgTreasury(DEFAULT_ORG_ID), newTreasury);
        _assertCommitmentStatus(commitmentId, CommitmentStatus.Settled);
    }

    function test_executorRotation_afterApplicationSubmission() public {
        address newExecutor = makeAddr("newExecutor");
        bytes32 appId1 = _submitApplication(applicant1);
        bytes32 appId2 = _submitApplication(applicant2);

        vm.startPrank(owner);
        responseCommitment.addExecutor(newExecutor);
        responseCommitment.removeExecutor(executor);
        vm.stopPrank();

        _respondToApplicationAs(appId1, newExecutor);

        bytes32 responseId = _generateResponseId(appId2);
        vm.prank(executor);
        vm.expectRevert(Errors.NotExecutor.selector);
        responseCommitment.recordApplicationResponse(appId2, responseId);

        _assertApplicationResponded(appId1);
        assertFalse(responseCommitment.application(appId2).isResponded);
    }

    function test_commitmentManagerGrantSurvivesTreasuryRotation() public {
        address commitmentManager = makeAddr("commitmentManager");
        address newTreasury = makeAddr("newTreasury");
        uint256 commitmentId = _activateCommitment(0);

        vm.prank(employer);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, commitmentManager, true);

        _rotateOrgTreasury(newTreasury);

        _stopCommitmentAs(commitmentId, commitmentManager);
        _settleCommitmentAs(commitmentId, commitmentManager, 0, 0, 0);

        uint256 amount = 1_000_000;
        vm.startPrank(commitmentManager);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, DEFAULT_ORG_ID, commitmentManager));
        commitmentFunds.depositWithAuthorization(
            DEFAULT_ORG_ID, amount, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, DEFAULT_ORG_ID, commitmentManager));
        commitmentFunds.withdraw(DEFAULT_ORG_ID, amount);
        vm.stopPrank();

        assertTrue(commitmentFunds.isCommitmentManager(DEFAULT_ORG_ID, commitmentManager));
        assertEq(orgRegistry.orgTreasury(DEFAULT_ORG_ID), newTreasury);
        _assertCommitmentStatus(commitmentId, CommitmentStatus.Settled);
    }

    function _rotateOrgTreasury(address newTreasury) private {
        vm.prank(employer);
        orgRegistry.proposeOrgTreasuryTransfer(DEFAULT_ORG_ID, newTreasury);

        vm.prank(newTreasury);
        orgRegistry.acceptOrgTreasuryTransfer(DEFAULT_ORG_ID);

        vm.prank(employer);
        orgRegistry.finalizeOrgTreasuryTransfer(DEFAULT_ORG_ID);
    }

    function _settleCommitmentAs(
        uint256 commitmentId,
        address submitter,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses
    ) private {
        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(totalApplications);
        bytes memory signature = _signCommitmentSettlement(
            commitmentId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            submitter,
            keyNonce,
            expiry
        );

        vm.prank(submitter);
        responseCommitment.settleCommitment(
            commitmentId,
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
