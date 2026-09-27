// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {CommitmentView} from "../../src/interfaces/IResponseCommitment.sol";
import {CommitmentStatus} from "../../src/types/CommitmentTypes.sol";

/// @title CommitmentLifecycleTest
/// @notice Tests commitment stopping and settlement.
contract CommitmentLifecycleTest is ResponseCommitmentTestBase {
    // ============ Stop Commitment Tests ============

    function test_stopCommitment_success() public {
        uint256 commitmentId = _activateCommitment(0);

        _stopCommitment(commitmentId);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Stopped));
        assertTrue(commitment.stoppedAt > 0);
    }

    function test_stopCommitment_alreadyStopped_reverts() public {
        uint256 commitmentId = _activateCommitment(0);

        _stopCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(commitmentId, employer, keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidCommitmentStatus.selector, CommitmentStatus.Stopped, CommitmentStatus.Active
            )
        );
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    function test_stopCommitment_alreadySettled_reverts() public {
        uint256 commitmentId = _activateCommitment(0);

        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(commitmentId, employer, keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidCommitmentStatus.selector, CommitmentStatus.Settled, CommitmentStatus.Active
            )
        );
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    function test_stopCommitment_commitmentNotFound_reverts() public {
        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(999, employer, keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentNotFound.selector, 999));
        responseCommitment.stopCommitment(999, keyNonce, expiry, signature);
    }

    function test_stopCommitment_expiredSignature_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(commitmentId, employer, keyNonce, expiry);

        vm.warp(expiry + 1);

        vm.prank(employer);
        vm.expectRevert(Errors.SignatureExpired.selector);
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    function test_stopCommitment_expiryAtCurrentTimestamp_succeeds() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp;
        bytes memory signature = _signCommitmentStop(commitmentId, employer, keyNonce, expiry);

        vm.prank(employer);
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);

        _assertCommitmentStatus(commitmentId, CommitmentStatus.Stopped);
    }

    function test_stopCommitment_commitmentManager_succeeds() public {
        uint256 commitmentId = _activateCommitment(0);

        vm.prank(employer);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, true);

        _stopCommitmentAs(commitmentId, applicant1);

        _assertCommitmentStatus(commitmentId, CommitmentStatus.Stopped);
    }

    function test_stopCommitment_nonManagerWithValidSignature_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(commitmentId, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotCommitmentManager.selector, DEFAULT_ORG_ID, applicant1));
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    function test_stopCommitment_revokedCommitmentManager_reverts() public {
        uint256 commitmentId = _activateCommitment(0);

        vm.startPrank(employer);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, true);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, false);
        vm.stopPrank();

        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(commitmentId, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotCommitmentManager.selector, DEFAULT_ORG_ID, applicant1));
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    function test_stopCommitment_invalidSignature_wrongSigner_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        uint256 wrongKey = 0x9999;
        bytes32 structHash = keccak256(abi.encode(COMMITMENT_STOP_TYPEHASH, commitmentId, employer, keyNonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", responseCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(employer);
        vm.expectRevert(Errors.InvalidSignature.selector);
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, badSig);
    }

    function test_stopCommitment_mismatchedStopper_reverts() public {
        uint256 commitmentId = _activateCommitment(0);

        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(commitmentId, employer, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    function test_stopCommitment_wrongNonceScope_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 keyNonce = _packKeyNonce(NONCE_SCOPE_COMMITMENT_SETTLEMENT, 1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(commitmentId, employer, keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidNonceScope.selector, NONCE_SCOPE_COMMITMENT_SETTLEMENT, NONCE_SCOPE_COMMITMENT_STOP
            )
        );
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    // ============ Settle Commitment Tests ============

    function test_settleCommitment_fromActive_success() public {
        uint256 commitmentId = _activateCommitment(0);

        _settleCommitment(commitmentId);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Settled));
        assertEq(commitment.stoppedAt, 0);
    }

    function test_settleCommitment_success_zeroCounters() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _settleCommitment(commitmentId);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Settled));

        uint256 orgOpBalAfter = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        assertEq(orgOpBalAfter, orgOpBalBefore);
    }

    function test_settleCommitment_nonZeroCountersRequireSnapshotRoot() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentSettlement(commitmentId, 1, 1, 1, bytes32(0), keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(Errors.CounterSnapshotRootRequired.selector);
        responseCommitment.settleCommitment(commitmentId, 1, 1, 1, bytes32(0), keyNonce, expiry, sig);
    }

    function test_settleCommitment_allOnTime_noSlash() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId, 2, 2, 2);

        uint256 orgOpBalAfter = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        assertEq(orgOpBalAfter, orgOpBalBefore);
    }

    function test_settleCommitment_commitmentManager_succeeds() public {
        uint256 commitmentId = _activateCommitment(0);

        vm.prank(employer);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, true);
        _stopCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory signature =
            _signCommitmentSettlement(commitmentId, 0, 0, 0, counterSnapshotRoot, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        responseCommitment.settleCommitment(commitmentId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry, signature);

        _assertCommitmentStatus(commitmentId, CommitmentStatus.Settled);
    }

    function test_settleCommitment_nonManagerWithValidSignature_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory signature =
            _signCommitmentSettlement(commitmentId, 0, 0, 0, counterSnapshotRoot, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotCommitmentManager.selector, DEFAULT_ORG_ID, applicant1));
        responseCommitment.settleCommitment(commitmentId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry, signature);
    }

    function test_settleCommitment_revokedCommitmentManager_reverts() public {
        uint256 commitmentId = _activateCommitment(0);

        vm.startPrank(employer);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, true);
        commitmentFunds.setCommitmentManager(DEFAULT_ORG_ID, applicant1, false);
        vm.stopPrank();
        _stopCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory signature =
            _signCommitmentSettlement(commitmentId, 0, 0, 0, counterSnapshotRoot, applicant1, keyNonce, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotCommitmentManager.selector, DEFAULT_ORG_ID, applicant1));
        responseCommitment.settleCommitment(commitmentId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry, signature);
    }

    function test_settleCommitment_70percentOnTime_usesSoftSlash() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId, 10, 10, 7);

        uint256 expectedSlash = (EMPLOYER_STAKE * 1200) / 10_000;

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - expectedSlash);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleCommitment_allLateAllResponded_30pctSoftSlash() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId, 2, 2, 0);

        uint256 expectedSlash = (EMPLOYER_STAKE * 3000) / 10_000;

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - expectedSlash);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleCommitment_notAllResponded_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentSettlement(commitmentId, 2, 1, 1, _counterSnapshotRoot(2), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotAllResponded.selector, 1, 2));
        responseCommitment.settleCommitment(commitmentId, 2, 1, 1, _counterSnapshotRoot(2), keyNonce, expiry, sig);
    }

    function test_settleCommitment_fromStoppedStatus_success() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Settled));
    }

    function test_settleCommitment_commitmentNotFound_reverts() public {
        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentSettlement(999, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentNotFound.selector, 999));
        responseCommitment.settleCommitment(999, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }

    function test_settleCommitment_alreadySettled_reverts() public {
        uint256 commitmentId = _activateCommitment(0);

        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentSettlement(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentAlreadySettled.selector, commitmentId));
        responseCommitment.settleCommitment(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }

    function test_settleCommitment_nonceReplay_reverts() public {
        uint256 commitmentId1 = _activateCommitment(0);
        uint256 commitmentId2 = _activateCommitment(0);
        _stopCommitment(commitmentId1);
        _stopCommitment(commitmentId2);

        uint256 usedKeyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig1 =
            _signCommitmentSettlement(commitmentId1, 0, 0, 0, _counterSnapshotRoot(0), usedKeyNonce, expiry);
        vm.prank(employer);
        responseCommitment.settleCommitment(commitmentId1, 0, 0, 0, _counterSnapshotRoot(0), usedKeyNonce, expiry, sig1);

        bytes memory sig2 =
            _signCommitmentSettlement(commitmentId2, 0, 0, 0, _counterSnapshotRoot(0), usedKeyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("InvalidAccountNonce(address,uint256)", operator, usedKeyNonce + 1));
        responseCommitment.settleCommitment(commitmentId2, 0, 0, 0, _counterSnapshotRoot(0), usedKeyNonce, expiry, sig2);
    }

    function test_settleCommitment_wrongNonceScope_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        uint256 keyNonce = _packKeyNonce(NONCE_SCOPE_COMMITMENT_ACTIVATION, 1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentSettlement(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidNonceScope.selector, NONCE_SCOPE_COMMITMENT_ACTIVATION, NONCE_SCOPE_COMMITMENT_SETTLEMENT
            )
        );
        responseCommitment.settleCommitment(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }

    function test_settleCommitment_wrongSettler_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig =
            _signCommitmentSettlement(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), applicant1, keyNonce, expiry);

        vm.prank(employer);
        vm.expectRevert(Errors.InvalidSignature.selector);
        responseCommitment.settleCommitment(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }

    // ============ Counter Invariant Validation ============

    function test_settleCommitment_onTimeExceedsResponded_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentSettlement(commitmentId, 2, 2, 3, _counterSnapshotRoot(2), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCounters.selector, 2, 2, 3));
        responseCommitment.settleCommitment(commitmentId, 2, 2, 3, _counterSnapshotRoot(2), keyNonce, expiry, sig);
    }

    function test_settleCommitment_respondedExceedsTotal_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentSettlement(commitmentId, 3, 5, 2, _counterSnapshotRoot(3), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCounters.selector, 3, 5, 2));
        responseCommitment.settleCommitment(commitmentId, 3, 5, 2, _counterSnapshotRoot(3), keyNonce, expiry, sig);
    }

    function test_settleCommitment_expired_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentSettlement(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);

        vm.warp(expiry + 1);

        vm.prank(employer);
        vm.expectRevert(Errors.SignatureExpired.selector);
        responseCommitment.settleCommitment(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }
}
