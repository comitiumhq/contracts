// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ResponseCommitmentStorageLayout} from "./ResponseCommitmentStorageLayout.sol";
import {SlashingLib} from "../libraries/SlashingLib.sol";
import {CommitmentAuthorizationLib} from "../libraries/CommitmentAuthorizationLib.sol";
import {Errors} from "../Errors.sol";
import {IResponseCommitment} from "../interfaces/IResponseCommitment.sol";

import {ICommitmentFunds} from "../interfaces/ICommitmentFunds.sol";
import {CommitmentConfig} from "../types/ConfigTypes.sol";
import {CommitmentExpiryStatus, Commitment, CommitmentStatus} from "../types/CommitmentTypes.sol";

/// @title CommitmentLifecycle
/// @notice Handles commitment stopping, settling, and expired settlement with stake settlement.
/// @dev Application counters are supplied at settlement and are not stored incrementally.
///      Both settlement paths require an EIP-712 operator signature over their exact counters.
abstract contract CommitmentLifecycle is ResponseCommitmentStorageLayout {
    using SafeCast for uint256;

    /// @notice Commitment funds contract.
    function _commitmentFunds() internal view virtual returns (ICommitmentFunds);

    // ============ Stop ============

    /// @notice Stop a commitment with operator signature verification.
    /// @param commitmentId Commitment to stop
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator EIP-712 signature
    function _stopCommitment(uint256 commitmentId, uint256 keyNonce, uint256 expiry, bytes calldata signature)
        internal
    {
        Commitment storage commitment = _commitment(commitmentId);

        if (commitment.creator == address(0)) revert Errors.CommitmentNotFound(commitmentId);
        if (commitment.status != CommitmentStatus.Active) {
            revert Errors.InvalidCommitmentStatus(commitment.status, CommitmentStatus.Active);
        }

        address stopper = _actor();

        _validateCommitmentStop(commitmentId, stopper, keyNonce, expiry, signature);
        _requireCommitmentManager(commitment.orgId, stopper);

        commitment.status = CommitmentStatus.Stopped;
        commitment.stoppedAt = block.timestamp.toUint40();

        emit IResponseCommitment.CommitmentStopped(commitmentId, commitment.orgId, stopper);
    }

    // ============ Settle ============

    /// @notice Settle an active or stopped commitment with operator-attested counters.
    /// @param commitmentId Commitment to settle
    /// @param totalApplications Total applications (operator-attested)
    /// @param respondedApplications Responded applications (operator-attested)
    /// @param onTimeResponses On-time responses (operator-attested)
    /// @param counterSnapshotRoot Merkle root of the application counter snapshot
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature over the counters
    function _settleCommitment(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) internal {
        Commitment storage commitment = _commitment(commitmentId);

        if (commitment.creator == address(0)) revert Errors.CommitmentNotFound(commitmentId);
        if (commitment.status == CommitmentStatus.Settled) revert Errors.CommitmentAlreadySettled(commitmentId);

        _validateCounters(totalApplications, respondedApplications, onTimeResponses);
        _validateCounterSnapshotRoot(totalApplications, counterSnapshotRoot);

        address settler = _actor();

        _validateCommitmentSettlement(
            commitmentId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            settler,
            keyNonce,
            expiry,
            signature
        );
        _requireCommitmentManager(commitment.orgId, settler);

        if (totalApplications > 0 && respondedApplications < totalApplications) {
            revert Errors.NotAllResponded(respondedApplications, totalApplications);
        }

        CommitmentConfig storage config = _commitmentConfigs[commitment.configVersion];
        uint256 slashRate = SlashingLib.calculateSlashRate(config.softSlashing, totalApplications, onTimeResponses);
        (uint256 slashAmount, uint256 returnAmount) = _finalizeSettlement(commitment, slashRate);

        emit IResponseCommitment.CommitmentSettled(
            commitmentId,
            commitment.orgId,
            settler,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            slashRate,
            returnAmount,
            slashAmount
        );

        _commitmentFunds().settleCommitment(commitment.orgId, commitmentId, returnAmount);
    }

    // ============ Expired Settlement ============

    /// @notice Settle an expired commitment and distribute stake.
    /// @dev An executor relays counters authorized by an EIP-712 operator signature.
    /// @param commitmentId Commitment to settle.
    /// @param totalApplications Total applications (operator-attested)
    /// @param respondedApplications Responded applications (operator-attested)
    /// @param onTimeResponses On-time responses (operator-attested)
    /// @param counterSnapshotRoot Merkle root of the application counter snapshot
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature over the counters
    function _settleExpiredCommitment(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) internal {
        Commitment storage commitment = _commitment(commitmentId);

        if (commitment.creator == address(0)) revert Errors.CommitmentNotFound(commitmentId);
        if (commitment.status == CommitmentStatus.Settled) revert Errors.CommitmentAlreadySettled(commitmentId);

        CommitmentConfig storage config = _commitmentConfigs[commitment.configVersion];

        (uint256 referenceTime, uint256 expirationPeriod, bool settleable) = _expirationWindow(commitment, config);

        if (!settleable) revert Errors.InvalidCommitmentStatus(commitment.status, CommitmentStatus.Settled);

        if (block.timestamp < referenceTime + expirationPeriod) {
            revert Errors.CommitmentNotExpired(referenceTime, expirationPeriod, block.timestamp);
        }

        _validateCounters(totalApplications, respondedApplications, onTimeResponses);
        _validateCounterSnapshotRoot(totalApplications, counterSnapshotRoot);
        _validateExpiredCommitmentSettlement(
            commitmentId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            keyNonce,
            expiry,
            signature
        );

        if (commitment.status == CommitmentStatus.Active) {
            commitment.status = CommitmentStatus.Stopped;
            commitment.stoppedAt = block.timestamp.toUint40();
            emit IResponseCommitment.CommitmentStopped(commitmentId, commitment.orgId, msg.sender);
        }

        uint256 slashRate =
            _expiredSettlementSlashRate(config, totalApplications, respondedApplications, onTimeResponses);
        (uint256 slashAmount, uint256 returnAmount) = _finalizeSettlement(commitment, slashRate);

        emit IResponseCommitment.ExpiredCommitmentSettled(
            commitmentId,
            commitment.orgId,
            msg.sender,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            slashRate,
            returnAmount,
            slashAmount
        );

        _commitmentFunds().settleCommitment(commitment.orgId, commitmentId, returnAmount);
    }

    // ============ View ============

    /// @notice Get expired settlement eligibility for a commitment.
    /// @param commitmentId Commitment ID.
    /// @return canSettle Whether the commitment can be expired-settled.
    /// @return status Reason the commitment can or cannot be expired-settled.
    function _expiredSettlementInfo(uint256 commitmentId)
        internal
        view
        returns (bool canSettle, CommitmentExpiryStatus status)
    {
        Commitment storage commitment = _commitment(commitmentId);

        if (commitment.creator == address(0)) return (false, CommitmentExpiryStatus.CommitmentNotFound);
        if (commitment.status == CommitmentStatus.Settled) return (false, CommitmentExpiryStatus.AlreadySettled);

        CommitmentConfig storage config = _commitmentConfigs[commitment.configVersion];

        (uint256 referenceTime, uint256 expirationPeriod, bool settleable) = _expirationWindow(commitment, config);

        assert(settleable);
        if (block.timestamp < referenceTime + expirationPeriod) return (false, CommitmentExpiryStatus.NotYetExpired);

        return (true, CommitmentExpiryStatus.Settleable);
    }

    // ============ Internal ============

    /// @notice Derive the expiry reference time and window for a settleable commitment.
    /// @param commitment Commitment storage reference.
    /// @param config Commitment configuration for the commitment's version.
    /// @return referenceTime Timestamp the expiry window is measured from.
    /// @return expirationPeriod Duration after referenceTime before the commitment may be expired-settled.
    /// @return settleable True when the commitment status is Active or Stopped.
    function _expirationWindow(Commitment storage commitment, CommitmentConfig storage config)
        private
        view
        returns (uint256 referenceTime, uint256 expirationPeriod, bool settleable)
    {
        if (commitment.status == CommitmentStatus.Active) {
            return (commitment.activatedAt, config.maxActiveDuration, true);
        }
        if (commitment.status == CommitmentStatus.Stopped) {
            return (commitment.stoppedAt, config.maxStoppedDuration, true);
        }

        return (0, 0, false);
    }

    /// @notice Validate counter invariants: onTime <= responded <= total
    function _validateCounters(uint32 totalApplications, uint32 respondedApplications, uint32 onTimeResponses)
        private
        pure
    {
        if (onTimeResponses > respondedApplications || respondedApplications > totalApplications) {
            revert Errors.InvalidCounters(totalApplications, respondedApplications, onTimeResponses);
        }
    }

    /// @notice Require a counter snapshot root whenever application counters are non-zero.
    function _validateCounterSnapshotRoot(uint32 totalApplications, bytes32 counterSnapshotRoot) private pure {
        if (totalApplications > 0 && counterSnapshotRoot == bytes32(0)) revert Errors.CounterSnapshotRootRequired();
    }

    /// @notice Select soft slashing when all applications were answered, harsh when any application was unanswered.
    function _expiredSettlementSlashRate(
        CommitmentConfig storage config,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses
    ) private view returns (uint256) {
        if (respondedApplications == totalApplications) {
            return SlashingLib.calculateSlashRate(config.softSlashing, totalApplications, onTimeResponses);
        }

        return SlashingLib.calculateSlashRate(config.harshSlashing, totalApplications, onTimeResponses);
    }

    /// @notice Shared finalization: settle the commitment and calculate stake settlement amounts.
    /// @param commitment Commitment storage reference
    /// @param slashRate Slash rate in basis points
    /// @return slashAmount Amount to be slashed (burned downstream during CommitmentFunds settlement)
    /// @return returnAmount Amount returned to org
    function _finalizeSettlement(Commitment storage commitment, uint256 slashRate)
        private
        returns (uint256 slashAmount, uint256 returnAmount)
    {
        (slashAmount, returnAmount) = SlashingLib.calculateSlashAmounts(commitment.stake, slashRate);

        commitment.status = CommitmentStatus.Settled;
        commitment.settledAt = block.timestamp.toUint40();
    }

    /// @notice Validate commitment stop signature using EIP-712.
    function _validateCommitmentStop(
        uint256 commitmentId,
        address stopper,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) private {
        bytes32 structHash = CommitmentAuthorizationLib.hashCommitmentStop(commitmentId, stopper, keyNonce, expiry);
        _consumeOperatorAuthorization(
            structHash, CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_STOP, keyNonce, expiry, signature
        );
    }

    /// @notice Validate commitment settle signature using EIP-712.
    function _validateCommitmentSettlement(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        address settler,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) private {
        bytes32 structHash = CommitmentAuthorizationLib.hashCommitmentSettlement(
            commitmentId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            settler,
            keyNonce,
            expiry
        );

        _consumeOperatorAuthorization(
            structHash, CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_SETTLEMENT, keyNonce, expiry, signature
        );
    }

    /// @notice Validate expired settlement counters using EIP-712.
    function _validateExpiredCommitmentSettlement(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) private {
        bytes32 structHash = CommitmentAuthorizationLib.hashExpiredCommitmentSettlement(
            commitmentId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            keyNonce,
            expiry
        );

        _consumeOperatorAuthorization(
            structHash,
            CommitmentAuthorizationLib.NONCE_SCOPE_EXPIRED_COMMITMENT_SETTLEMENT,
            keyNonce,
            expiry,
            signature
        );
    }

    function _requireCommitmentManager(uint256 orgId, address account) private view {
        if (!_commitmentFunds().canManageCommitments(orgId, account)) {
            revert Errors.NotCommitmentManager(orgId, account);
        }
    }
}
