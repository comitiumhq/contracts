// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Job lifecycle status.
enum JobStatus {
    Published,
    Unpublished,
    Closed
}

/// @notice Reason a job can or cannot be settled after expiry.
enum JobExpiryStatus {
    Settleable,
    JobNotFound,
    AlreadySettled,
    AlreadyClosed,
    NotYetExpired
}

/// @notice Job data stored by a concrete JobCommitment deployment.
struct Job {
    /// @notice Stable reference to the product job posting.
    bytes32 postingRef;

    /// @notice Account that initiated job creation.
    address creator;

    /// @notice Original org stake locked for this job (USDC 6 decimals).
    uint96 stake;

    /// @notice Timestamp when the job was created.
    uint40 createdAt;

    /// @notice Timestamp when the job was unpublished.
    uint40 unpublishedAt;

    /// @notice Timestamp when the job was closed and settled.
    uint40 closedAt;

    /// @notice Fee tier selected at creation.
    uint8 feeTier;

    /// @notice Current lifecycle status.
    JobStatus status;

    /// @notice Whether the org stake has been settled through JobFunds.
    bool orgStakeSettled;

    /// @notice Job configuration version snapshotted at creation.
    uint32 configVersion;

    /// @notice Organization that owns the job.
    uint96 orgId;

    /// @notice Non-refundable publishing fee paid at creation (USDC 6 decimals).
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
