// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {JobStorageLayout} from "./JobStorageLayout.sol";
import {JobLib} from "../libraries/JobLib.sol";
import {JobAuthorizationLib} from "../libraries/JobAuthorizationLib.sol";
import {IJobCommitment} from "../interfaces/IJobCommitment.sol";
import {Errors} from "../Errors.sol";

import {FeeTier, JobConfig} from "../types/ConfigTypes.sol";
import {Job, JobStatus} from "../types/JobTypes.sol";

/// @title JobPublish
/// @notice Job commitment publication via operator signatures.
abstract contract JobPublish is JobStorageLayout {
    using SafeCast for uint256;

    /// @notice Publish a new job posting with operator signature verification
    /// @param orgId Organization ID
    /// @param stake Amount of USDC to stake
    /// @param feeTier Configured fee tier index
    /// @param expectedFeeAmount Exact publishing fee authorized by the creator
    /// @param postingRef Stable product posting reference
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
        bytes32 postingRef,
        address creator,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) internal returns (uint256 jobId) {
        uint32 configVersion = _currentConfigVersion;
        JobConfig storage config = _jobConfigs[configVersion];

        if (stake < config.minStake) revert Errors.StakeTooLow(stake, config.minStake);
        if (feeTier >= config.tierCount) revert Errors.InvalidFeeTier(feeTier);
        if (postingRef == bytes32(0)) revert Errors.ZeroPostingRef();

        _validateJobPublish(orgId, stake, feeTier, postingRef, creator, configVersion, keyNonce, expiry, signature);

        jobId = _initializeJob(orgId, stake, feeTier, expectedFeeAmount, postingRef, configVersion, creator);
    }

    /// @dev Split from _publishJob to keep stack usage below compiler limits.
    function _initializeJob(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        uint256 expectedFeeAmount,
        bytes32 postingRef,
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

        _storeJob(jobId, orgId, postingRef, boundedStake, feeTier, fee, configVersion, creator);

        emit IJobCommitment.JobPublished(
            jobId, orgId, creator, configVersion, stake, fee, responseDeadlineDays, postingRef
        );

        return jobId;
    }

    /// @dev Stores job fields separately to keep _initializeJob below compiler stack limits.
    function _storeJob(
        uint256 jobId,
        uint256 orgId,
        bytes32 postingRef,
        uint96 stake,
        uint8 feeTier,
        uint256 fee,
        uint32 configVersion,
        address creator
    ) private {
        Job storage job = _jobs[jobId];
        job.postingRef = postingRef;
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
        bytes32 postingRef,
        address creator,
        uint32 configVersion,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) private {
        bytes32 structHash = JobAuthorizationLib.hashJobPublish(
            orgId, stake, feeTier, postingRef, creator, configVersion, keyNonce, expiry
        );
        _consumeOperatorAuthorization(
            structHash, JobAuthorizationLib.NONCE_SCOPE_JOB_PUBLISH, keyNonce, expiry, signature
        );
    }
}
