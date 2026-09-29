// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {BASIS_POINTS} from "../Constants.sol";
import {FeeTier, CommitmentConfig, SlashingTable} from "../types/ConfigTypes.sol";
import {Errors} from "../Errors.sol";

// ============ Validation Bounds ============

uint96 constant MIN_STAKE_LOWER = 50_000_000; // $50
uint96 constant MIN_STAKE_UPPER = 300_000_000; // $300
uint96 constant TIER_BASE_FEE_UPPER = 250_000_000; // $250
uint16 constant FEE_BPS_LOWER = 100; // 1%
uint16 constant FEE_BPS_UPPER = 500; // 5%
uint8 constant MIN_FEE_TIERS = 1;
uint8 constant MAX_FEE_TIERS = 10;
uint8 constant APPLICATION_DEADLINE_DAYS_UPPER = 30;
uint16 constant MAX_BATCH_SIZE_UPPER = 50;
uint32 constant MAX_STOPPED_DURATION_LOWER = 30 days;
uint32 constant MAX_STOPPED_DURATION_UPPER = 365 days;
uint32 constant MAX_ACTIVE_DURATION_LOWER = 90 days;
uint32 constant MAX_ACTIVE_DURATION_UPPER = 730 days;

/// @title ConfigValidationLib
/// @notice Validation logic for protocol configuration parameters
/// @dev Internal-only helper library; it does not require deployment or linking.
library ConfigValidationLib {
    /// @notice Validate a versioned commitment configuration.
    /// @param c Commitment configuration to validate.
    function validateCommitmentConfig(CommitmentConfig memory c) internal pure {
        if (c.minStake < MIN_STAKE_LOWER) revert Errors.ConfigValueTooLow("minStake");
        if (c.minStake > MIN_STAKE_UPPER) revert Errors.ConfigValueTooHigh("minStake");
        if (c.tierCount < MIN_FEE_TIERS || c.tierCount > MAX_FEE_TIERS) {
            revert Errors.ConfigValueOutOfRange("tierCount");
        }

        if (c.maxBatchSize == 0 || c.maxBatchSize > MAX_BATCH_SIZE_UPPER) {
            revert Errors.ConfigValueOutOfRange("maxBatchSize");
        }

        if (c.maxStoppedDuration < MAX_STOPPED_DURATION_LOWER || c.maxStoppedDuration > MAX_STOPPED_DURATION_UPPER) {
            revert Errors.ConfigValueOutOfRange("maxStoppedDuration");
        }

        if (c.maxActiveDuration < MAX_ACTIVE_DURATION_LOWER || c.maxActiveDuration > MAX_ACTIVE_DURATION_UPPER) {
            revert Errors.ConfigValueOutOfRange("maxActiveDuration");
        }

        if (c.maxActiveDuration <= c.maxStoppedDuration) revert Errors.InvalidDurationOrdering();

        _validateSlashingTable(c.harshSlashing);
        _validateSlashingTable(c.softSlashing);
        _validateHarshVsSoft(c.harshSlashing, c.softSlashing);
    }

    /// @notice Validate dynamic fee tiers for one commitment config version.
    /// @param tiers Fee tiers ordered from cheapest/shortest to highest/longest.
    function validateFeeTiers(FeeTier[] memory tiers) internal pure {
        if (tiers.length < MIN_FEE_TIERS || tiers.length > MAX_FEE_TIERS) {
            revert Errors.ConfigValueOutOfRange("tierCount");
        }

        uint96 previousBaseFee;
        uint16 previousFeeBps;
        uint8 previousDeadlineDays;

        for (uint256 i = 0; i < tiers.length; i++) {
            FeeTier memory tier = tiers[i];

            if (tier.baseFee > TIER_BASE_FEE_UPPER) revert Errors.ConfigValueTooHigh("baseFee");

            if (tier.feeBps < FEE_BPS_LOWER || tier.feeBps > FEE_BPS_UPPER) {
                revert Errors.ConfigValueOutOfRange("feeBps");
            }

            if (tier.deadlineDays == 0 || tier.deadlineDays > APPLICATION_DEADLINE_DAYS_UPPER) {
                revert Errors.ConfigValueOutOfRange("deadlineDays");
            }

            if (i > 0) {
                if (tier.deadlineDays <= previousDeadlineDays) revert Errors.InvalidTierOrdering();
                if (tier.baseFee < previousBaseFee) revert Errors.InvalidTierOrdering();
                if (tier.feeBps < previousFeeBps) revert Errors.InvalidTierOrdering();
                if (tier.baseFee == previousBaseFee && tier.feeBps == previousFeeBps) {
                    revert Errors.InvalidTierOrdering();
                }
            }

            previousBaseFee = tier.baseFee;
            previousFeeBps = tier.feeBps;
            previousDeadlineDays = tier.deadlineDays;
        }
    }

    function _validateSlashingTable(SlashingTable memory t) private pure {
        if (
            t.zeroResponseRate > BASIS_POINTS || t.below50Rate > BASIS_POINTS || t.rate50 > BASIS_POINTS
                || t.rate60 > BASIS_POINTS || t.rate70 > BASIS_POINTS || t.rate80 > BASIS_POINTS
                || t.rate90 > BASIS_POINTS || t.rate95 > BASIS_POINTS
        ) revert Errors.ConfigValueTooHigh("slashRate");

        if (
            t.below50Rate > t.zeroResponseRate || t.rate50 > t.below50Rate || t.rate60 > t.rate50 || t.rate70 > t.rate60
                || t.rate80 > t.rate70 || t.rate90 > t.rate80 || t.rate95 > t.rate90
        ) revert Errors.InvalidSlashingOrdering();
    }

    function _validateHarshVsSoft(SlashingTable memory harsh, SlashingTable memory soft) private pure {
        if (
            harsh.zeroResponseRate < soft.zeroResponseRate || harsh.below50Rate < soft.below50Rate
                || harsh.rate50 < soft.rate50 || harsh.rate60 < soft.rate60 || harsh.rate70 < soft.rate70
                || harsh.rate80 < soft.rate80 || harsh.rate90 < soft.rate90 || harsh.rate95 < soft.rate95
        ) revert Errors.InvalidSlashingOrdering();
    }
}
