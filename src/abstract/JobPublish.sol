// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {JobStorageLayout} from "./JobStorageLayout.sol";
import {JobLib} from "../libraries/JobLib.sol";
import {JobAuthorizationLib} from "../libraries/JobAuthorizationLib.sol";
import {IJobCommitment} from "../interfaces/IJobCommitment.sol";
import {Errors} from "../Errors.sol";

import {IJobFunds} from "../interfaces/IJobFunds.sol";
import {FeeTier, JobConfig} from "../types/ConfigTypes.sol";
import {Job, JobStatus} from "../types/JobTypes.sol";

/// @title JobPublish
/// @notice Job posting authoring: publication (with funding) and content-URI updates, via operator signatures.
abstract contract JobPublish is JobStorageLayout {
    using SafeCast for uint256;

    /// @notice Job funds contract used for org job-manager authorization.
    function _jobFunds() internal view virtual returns (IJobFunds);

    /// @notice Publish a new job posting with operator signature verification
    /// @param orgId Organization ID
    /// @param stake Amount of USDC to stake
    /// @param feeTier Configured fee tier index
    /// @param expectedFeeAmount Exact publishing fee authorized by the creator
    /// @param contentURI IPFS URI containing job metadata
    /// @param creator Authorized org manager that initiated publication
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator EIP-712 signature
    /// @return jobId The ID of the published job
    function _publishJob(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        uint256 expectedFeeAmount,
        string memory contentURI,
        address creator,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) internal returns (uint256 jobId) {
        uint32 configVersion = _currentConfigVersion;
        JobConfig storage config = _jobConfigs[configVersion];

        if (stake < config.minStake) revert Errors.StakeTooLow(stake, config.minStake);
        if (feeTier >= config.tierCount) revert Errors.InvalidFeeTier(feeTier);
        if (bytes(contentURI).length == 0) revert Errors.EmptyContentURI();

        _validateJobPublish(orgId, stake, feeTier, contentURI, creator, configVersion, keyNonce, expiry, signature);

        jobId = _initializeJob(orgId, stake, feeTier, expectedFeeAmount, contentURI, configVersion, creator);
    }

    /// @dev Split from _publishJob to keep stack usage below compiler limits.
    function _initializeJob(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        uint256 expectedFeeAmount,
        string memory contentURI,
        uint32 configVersion,
        address creator
    ) private returns (uint256 jobId) {
        FeeTier storage tier = _feeTiers[configVersion][feeTier];
        uint96 boundedStake = stake.toUint96();

        uint256 fee = JobLib.getFeeAmount(tier, boundedStake);
        if (fee != expectedFeeAmount) revert Errors.FeeAmountMismatch(expectedFeeAmount, fee);

        uint8 responseDeadlineDays = tier.deadlineDays;

        _nextJobId++;
        jobId = _nextJobId;

        _storeJob(jobId, orgId, boundedStake, feeTier, fee, configVersion, creator);
        _setContentURI(jobId, contentURI);

        emit IJobCommitment.JobPublished(
            jobId, orgId, creator, configVersion, stake, fee, responseDeadlineDays, contentURI
        );

        return jobId;
    }

    /// @dev Stores job fields separately to keep _initializeJob below compiler stack limits.
    function _storeJob(
        uint256 jobId,
        uint256 orgId,
        uint96 stake,
        uint8 feeTier,
        uint256 fee,
        uint32 configVersion,
        address creator
    ) private {
        Job storage job = _jobs[jobId];
        job.creator = creator;
        job.stake = stake;
        job.createdAt = block.timestamp.toUint40();
        job.feeTier = feeTier;
        job.status = JobStatus.Published;
        job.orgId = orgId.toUint96();
        job.feeAmount = fee.toUint96();
        job.configVersion = configVersion;
    }

    // ============ Internal ============

    /// @notice Validate job publication signature using EIP-712
    function _validateJobPublish(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        string memory contentURI,
        address creator,
        uint32 configVersion,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) private {
        bytes32 structHash = JobAuthorizationLib.hashJobPublish(
            orgId, stake, feeTier, contentURI, creator, configVersion, keyNonce, expiry
        );
        _consumeOperatorAuthorization(
            structHash, JobAuthorizationLib.NONCE_SCOPE_JOB_PUBLISH, keyNonce, expiry, signature
        );
    }

    // ============ Update ============

    /// @notice Update a published job's content URI after operator approval.
    /// @param jobId Job ID.
    /// @param contentURI New content URI (must be non-empty).
    /// @param keyNonce Scoped key nonce for replay protection.
    /// @param expiry Operator signature expiry timestamp.
    /// @param signature Operator EIP-712 signature over the update payload.
    function _updateJobContentURI(
        uint256 jobId,
        string calldata contentURI,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) internal {
        Job storage job = _job(jobId);

        if (job.creator == address(0)) revert Errors.JobNotFound(jobId);
        if (job.status != JobStatus.Published) revert Errors.InvalidJobStatus(job.status, JobStatus.Published);
        if (bytes(contentURI).length == 0) revert Errors.EmptyContentURI();

        address updater = _actor();

        _validateJobContentURIUpdate(jobId, contentURI, updater, keyNonce, expiry, signature);
        _requireContentUpdateJobManager(job.orgId, updater);
        _setContentURI(jobId, contentURI);

        emit IJobCommitment.JobContentURIUpdated(jobId, job.orgId, updater, contentURI);
    }

    function _validateJobContentURIUpdate(
        uint256 jobId,
        string calldata contentURI,
        address updater,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) private {
        bytes32 structHash = JobAuthorizationLib.hashJobContentURIUpdate(jobId, contentURI, updater, keyNonce, expiry);
        _consumeOperatorAuthorization(
            structHash, JobAuthorizationLib.NONCE_SCOPE_JOB_CONTENT_URI_UPDATE, keyNonce, expiry, signature
        );
    }

    function _requireContentUpdateJobManager(uint256 orgId, address account) private view {
        if (!_jobFunds().canManageJobs(orgId, account)) revert Errors.NotJobManager(orgId, account);
    }
}
