// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Slashing rates for each on-time response rate bracket
/// @dev Fixed brackets: [0%, 1-49%, 50-59%, 60-69%, 70-79%, 80-89%, 90-94%, 95-99%]
///      100% on-time response rate is always 0 slash (hardcoded invariant)
struct SlashingTable {
    uint16 zeroResponseRate; // 0 on-time responses
    uint16 below50Rate; // 1-49%
    uint16 rate50; // 50-59%
    uint16 rate60; // 60-69%
    uint16 rate70; // 70-79%
    uint16 rate80; // 80-89%
    uint16 rate90; // 90-94%
    uint16 rate95; // 95-99%
}

/// @notice Fee and response deadline for one commitment activation tier
struct FeeTier {
    uint96 baseFee; // fixed non-refundable tier fee (USDC 6 decimals)
    uint16 feeBps; // stake-scaled fee in basis points
    uint8 deadlineDays; // response deadline in days
}

/// @notice Complete economic configuration for commitment operations
/// @dev FeeTier values are stored separately per config version.
struct CommitmentConfig {
    uint96 minStake; // minimum org stake (USDC 6 decimals)
    uint8 tierCount; // number of active fee tiers for this version
    uint16 maxBatchSize; // operational response batch limit
    uint32 maxStoppedDuration; // seconds, expired settlement window after stop
    uint32 maxActiveDuration; // seconds, expired settlement window after activation
    SlashingTable harshSlashing; // expired settlement slashing rates
    SlashingTable softSlashing; // normal settle slashing rates
}
