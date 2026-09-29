// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ResponseCommitmentStorageLayout} from "./ResponseCommitmentStorageLayout.sol";
import {CommitmentLib} from "../libraries/CommitmentLib.sol";
import {CommitmentAuthorizationLib} from "../libraries/CommitmentAuthorizationLib.sol";
import {IResponseCommitment} from "../interfaces/IResponseCommitment.sol";
import {Errors} from "../Errors.sol";

import {FeeTier, CommitmentConfig} from "../types/ConfigTypes.sol";
import {Commitment, CommitmentStatus} from "../types/CommitmentTypes.sol";

/// @title CommitmentActivation
/// @notice Commitment activation via operator signatures.
abstract contract CommitmentActivation is ResponseCommitmentStorageLayout {
    using SafeCast for uint256;

    /// @notice Activate a response commitment for an offchain posting.
    /// @param orgId Organization ID
    /// @param stake Amount of USDC to stake
    /// @param feeTier Configured fee tier index
    /// @param expectedFeeAmount Exact activation fee authorized by the creator
    /// @param postingRef Stable product posting reference
    /// @param creator Org admin or commitment manager that initiated activation
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator EIP-712 signature
    /// @return commitmentId The ID of the active commitment
    function _activateCommitment(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        uint256 expectedFeeAmount,
        bytes32 postingRef,
        address creator,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) internal returns (uint256 commitmentId) {
        uint32 configVersion = _currentConfigVersion;
        CommitmentConfig storage config = _commitmentConfigs[configVersion];

        if (stake < config.minStake) revert Errors.StakeTooLow(stake, config.minStake);
        if (feeTier >= config.tierCount) revert Errors.InvalidFeeTier(feeTier);
        if (postingRef == bytes32(0)) revert Errors.ZeroPostingRef();

        _validateCommitmentActivation(
            orgId, stake, feeTier, postingRef, creator, configVersion, keyNonce, expiry, signature
        );

        commitmentId =
            _initializeCommitment(orgId, stake, feeTier, expectedFeeAmount, postingRef, configVersion, creator);
    }

    /// @dev Split from _activateCommitment to keep stack usage below compiler limits.
    function _initializeCommitment(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        uint256 expectedFeeAmount,
        bytes32 postingRef,
        uint32 configVersion,
        address creator
    ) private returns (uint256 commitmentId) {
        FeeTier storage tier = _feeTiers[configVersion][feeTier];
        uint96 boundedStake = stake.toUint96();

        uint256 fee = CommitmentLib.getFeeAmount(tier, boundedStake);
        if (fee != expectedFeeAmount) revert Errors.FeeAmountMismatch(expectedFeeAmount, fee);

        uint8 responseDeadlineDays = tier.deadlineDays;

        _nextCommitmentId++;
        commitmentId = _nextCommitmentId;

        _storeCommitment(commitmentId, orgId, postingRef, boundedStake, feeTier, fee, configVersion, creator);

        emit IResponseCommitment.CommitmentActivated(
            commitmentId, orgId, creator, configVersion, stake, fee, responseDeadlineDays, postingRef
        );

        return commitmentId;
    }

    /// @dev Stores commitment fields separately to keep _initializeCommitment below compiler stack limits.
    function _storeCommitment(
        uint256 commitmentId,
        uint256 orgId,
        bytes32 postingRef,
        uint96 stake,
        uint8 feeTier,
        uint256 fee,
        uint32 configVersion,
        address creator
    ) private {
        Commitment storage commitment = _commitments[commitmentId];

        commitment.postingRef = postingRef;
        commitment.creator = creator;
        commitment.stake = stake;
        commitment.activatedAt = block.timestamp.toUint40();
        commitment.feeTier = feeTier;
        commitment.status = CommitmentStatus.Active;
        commitment.orgId = orgId.toUint96();
        commitment.feeAmount = fee.toUint96();
        commitment.configVersion = configVersion;
    }

    // ============ Internal ============

    /// @notice Validate a commitment activation signature using EIP-712.
    function _validateCommitmentActivation(
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
        bytes32 structHash = CommitmentAuthorizationLib.hashCommitmentActivation(
            orgId, stake, feeTier, postingRef, creator, configVersion, keyNonce, expiry
        );

        _consumeOperatorAuthorization(
            structHash, CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_ACTIVATION, keyNonce, expiry, signature
        );
    }
}
