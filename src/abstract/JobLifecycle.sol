// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {JobStorageLayout} from "./JobStorageLayout.sol";
import {SlashingLib} from "../libraries/SlashingLib.sol";
import {JobAuthorizationLib} from "../libraries/JobAuthorizationLib.sol";
import {Errors} from "../Errors.sol";
import {IJobCommitment} from "../interfaces/IJobCommitment.sol";

import {IJobFunds} from "../interfaces/IJobFunds.sol";
import {JobConfig} from "../types/ConfigTypes.sol";
import {JobExpiryStatus, Job, JobStatus} from "../types/JobTypes.sol";

/// @title JobLifecycle
/// @notice Handles job unpublishing, closing, and expired settlement with stake settlement.
/// @dev Application counters are supplied at settlement and are not stored incrementally.
///      Both settlement paths require an EIP-712 operator signature over their exact counters.
abstract contract JobLifecycle is JobStorageLayout {
    using SafeCast for uint256;

    /// @notice Job funds contract.
    function _jobFunds() internal view virtual returns (IJobFunds);

    // ============ Unpublish ============

    /// @notice Unpublish a job with operator signature verification.
    /// @param jobId Job to unpublish
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator EIP-712 signature
    function _unpublishJob(uint256 jobId, uint256 keyNonce, uint256 expiry, bytes calldata signature) internal {
        Job storage job = _job(jobId);

        if (job.creator == address(0)) revert Errors.JobNotFound(jobId);
        if (job.status != JobStatus.Published) revert Errors.InvalidJobStatus(job.status, JobStatus.Published);

        address unpublisher = _actor();

        _validateJobUnpublish(jobId, unpublisher, keyNonce, expiry, signature);
        _requireJobManager(job.orgId, unpublisher);

        job.status = JobStatus.Unpublished;
        job.unpublishedAt = block.timestamp.toUint40();

        emit IJobCommitment.JobUnpublished(jobId, job.orgId, unpublisher);
    }

    // ============ Close ============

    /// @notice Close a published or unpublished job with operator-attested counters.
    /// @param jobId Job to close
    /// @param totalApplications Total applications (operator-attested)
    /// @param respondedApplications Responded applications (operator-attested)
    /// @param onTimeResponses On-time responses (operator-attested)
    /// @param counterSnapshotRoot Merkle root of the application counter snapshot
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature over the counters
    function _closeJob(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) internal {
        Job storage job = _job(jobId);

        if (job.creator == address(0)) revert Errors.JobNotFound(jobId);
        if (job.status == JobStatus.Closed) revert Errors.JobAlreadyClosed(jobId);

        _validateCounters(totalApplications, respondedApplications, onTimeResponses);
        _validateCounterSnapshotRoot(totalApplications, counterSnapshotRoot);

        address closer = _actor();

        _validateJobClose(
            jobId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            closer,
            keyNonce,
            expiry,
            signature
        );
        _requireJobManager(job.orgId, closer);

        if (totalApplications > 0 && respondedApplications < totalApplications) {
            revert Errors.NotAllResponded(respondedApplications, totalApplications);
        }

        JobConfig storage config = _jobConfigs[job.configVersion];
        uint256 slashRate = SlashingLib.calculateSlashRate(config.softSlashing, totalApplications, onTimeResponses);
        (uint256 slashAmount, uint256 returnAmount) = _finalizeClose(job, slashRate);

        emit IJobCommitment.JobClosed(
            jobId,
            job.orgId,
            closer,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            slashRate,
            returnAmount,
            slashAmount
        );

        _jobFunds().settleJob(job.orgId, jobId, returnAmount);
    }

    // ============ Expired Settlement ============

    /// @notice Settle an expired job and distribute stake.
    /// @dev An executor relays counters authorized by an EIP-712 operator signature.
    /// @param jobId Job to settle.
    /// @param totalApplications Total applications (operator-attested)
    /// @param respondedApplications Responded applications (operator-attested)
    /// @param onTimeResponses On-time responses (operator-attested)
    /// @param counterSnapshotRoot Merkle root of the application counter snapshot
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature over the counters
    function _settleExpiredJob(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) internal {
        Job storage job = _job(jobId);

        if (job.creator == address(0)) revert Errors.JobNotFound(jobId);
        if (job.orgStakeSettled) revert Errors.OrgStakeAlreadySettled(jobId);

        JobConfig storage config = _jobConfigs[job.configVersion];

        (uint256 referenceTime, uint256 expirationPeriod, bool settleable) = _expirationWindow(job, config);

        if (!settleable) revert Errors.InvalidJobStatus(job.status, JobStatus.Closed);

        if (block.timestamp < referenceTime + expirationPeriod) {
            revert Errors.JobNotExpired(referenceTime, expirationPeriod, block.timestamp);
        }

        _validateCounters(totalApplications, respondedApplications, onTimeResponses);
        _validateCounterSnapshotRoot(totalApplications, counterSnapshotRoot);
        _validateJobExpiredSettlement(
            jobId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            keyNonce,
            expiry,
            signature
        );

        if (job.status == JobStatus.Published) {
            job.status = JobStatus.Unpublished;
            job.unpublishedAt = block.timestamp.toUint40();
            emit IJobCommitment.JobUnpublished(jobId, job.orgId, msg.sender);
        }

        uint256 slashRate =
            _expiredSettlementSlashRate(config, totalApplications, respondedApplications, onTimeResponses);
        (uint256 slashAmount, uint256 returnAmount) = _finalizeClose(job, slashRate);

        emit IJobCommitment.JobExpiredSettled(
            jobId,
            job.orgId,
            msg.sender,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            slashRate,
            returnAmount,
            slashAmount
        );

        _jobFunds().settleJob(job.orgId, jobId, returnAmount);
    }

    // ============ View ============

    /// @notice Get expired settlement eligibility for a job.
    /// @param jobId Job ID.
    /// @return canSettle Whether the job can be expired-settled.
    /// @return status Reason the job can or cannot be expired-settled.
    function _expiredSettlementInfo(uint256 jobId) internal view returns (bool canSettle, JobExpiryStatus status) {
        Job storage job = _job(jobId);

        if (job.creator == address(0)) return (false, JobExpiryStatus.JobNotFound);
        if (job.orgStakeSettled) return (false, JobExpiryStatus.AlreadySettled);

        JobConfig storage config = _jobConfigs[job.configVersion];

        (uint256 referenceTime, uint256 expirationPeriod, bool settleable) = _expirationWindow(job, config);

        if (!settleable) return (false, JobExpiryStatus.AlreadyClosed);
        if (block.timestamp < referenceTime + expirationPeriod) return (false, JobExpiryStatus.NotYetExpired);

        return (true, JobExpiryStatus.Settleable);
    }

    // ============ Internal ============

    /// @notice Derive the expiry reference time and window for a settleable job.
    /// @param job Job storage reference.
    /// @param config Job configuration for the job's version.
    /// @return referenceTime Timestamp the expiry window is measured from.
    /// @return expirationPeriod Duration after referenceTime before the job may be expired-settled.
    /// @return settleable True when the job status is Published or Unpublished.
    function _expirationWindow(Job storage job, JobConfig storage config)
        private
        view
        returns (uint256 referenceTime, uint256 expirationPeriod, bool settleable)
    {
        if (job.status == JobStatus.Published) return (job.createdAt, config.maxPublishedDuration, true);
        if (job.status == JobStatus.Unpublished) return (job.unpublishedAt, config.maxUnpublishedDuration, true);

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
        JobConfig storage config,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses
    ) private view returns (uint256) {
        if (respondedApplications == totalApplications) {
            return SlashingLib.calculateSlashRate(config.softSlashing, totalApplications, onTimeResponses);
        }

        return SlashingLib.calculateSlashRate(config.harshSlashing, totalApplications, onTimeResponses);
    }

    /// @notice Shared finalization: close the job and calculate stake settlement amounts.
    /// @param job Job storage reference
    /// @param slashRate Slash rate in basis points
    /// @return slashAmount Amount to be slashed (burned downstream during JobFunds settlement)
    /// @return returnAmount Amount returned to org
    function _finalizeClose(Job storage job, uint256 slashRate)
        private
        returns (uint256 slashAmount, uint256 returnAmount)
    {
        (slashAmount, returnAmount) = SlashingLib.calculateSlashAmounts(job.stake, slashRate);

        job.status = JobStatus.Closed;
        job.closedAt = block.timestamp.toUint40();
        job.orgStakeSettled = true;
    }

    /// @notice Validate job unpublish signature using EIP-712.
    function _validateJobUnpublish(
        uint256 jobId,
        address unpublisher,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) private {
        bytes32 structHash = JobAuthorizationLib.hashJobUnpublish(jobId, unpublisher, keyNonce, expiry);
        _consumeOperatorAuthorization(
            structHash, JobAuthorizationLib.NONCE_SCOPE_JOB_UNPUBLISH, keyNonce, expiry, signature
        );
    }

    /// @notice Validate job close signature using EIP-712.
    function _validateJobClose(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        address closer,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) private {
        bytes32 structHash = JobAuthorizationLib.hashJobClose(
            jobId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            closer,
            keyNonce,
            expiry
        );

        _consumeOperatorAuthorization(
            structHash, JobAuthorizationLib.NONCE_SCOPE_JOB_CLOSE, keyNonce, expiry, signature
        );
    }

    /// @notice Validate expired settlement counters using EIP-712.
    function _validateJobExpiredSettlement(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) private {
        bytes32 structHash = JobAuthorizationLib.hashJobExpiredSettlement(
            jobId, totalApplications, respondedApplications, onTimeResponses, counterSnapshotRoot, keyNonce, expiry
        );

        _consumeOperatorAuthorization(
            structHash, JobAuthorizationLib.NONCE_SCOPE_JOB_EXPIRED_SETTLEMENT, keyNonce, expiry, signature
        );
    }

    function _requireJobManager(uint256 orgId, address account) private view {
        if (!_jobFunds().canManageJobs(orgId, account)) revert Errors.NotJobManager(orgId, account);
    }
}
