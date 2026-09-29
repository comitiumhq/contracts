// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Commitment lifecycle status.
enum CommitmentStatus {
    Active,
    Stopped,
    Settled
}

/// @notice Reason a commitment can or cannot be settled after expiry.
enum CommitmentExpiryStatus {
    Settleable,
    CommitmentNotFound,
    AlreadySettled,
    NotYetExpired
}

/// @notice Commitment data stored by a concrete ResponseCommitment deployment.
struct Commitment {
    /// @notice Stable reference to the product Job Posting covered by the commitment.
    bytes32 postingRef;

    /// @notice Account that initiated commitment creation.
    address creator;

    /// @notice Original org stake locked for this commitment (USDC 6 decimals).
    uint96 stake;

    /// @notice Timestamp when the commitment was activated.
    uint40 activatedAt;

    /// @notice Timestamp when the commitment was stopped.
    uint40 stoppedAt;

    /// @notice Timestamp when the commitment and its stake were settled.
    uint40 settledAt;

    /// @notice Fee tier selected at creation.
    uint8 feeTier;

    /// @notice Current lifecycle status.
    CommitmentStatus status;

    /// @notice Commitment configuration version snapshotted at creation.
    uint32 configVersion;

    /// @notice Organization that owns the commitment.
    uint96 orgId;

    /// @notice Non-refundable activation fee paid at creation (USDC 6 decimals).
    uint96 feeAmount;
}

/// @notice On-chain application state keyed by an opaque application ID.
struct Application {
    /// @notice Account that submitted the application.
    address applicant;

    /// @notice Timestamp when the application was submitted.
    uint40 appliedAt;

    /// @notice Timestamp by which the employer should respond.
    uint40 responseDeadline;

    /// @notice Timestamp when an executor marked the application as responded.
    uint40 respondedAt;

    /// @notice Whether the application has been responded to.
    bool isResponded;
}
