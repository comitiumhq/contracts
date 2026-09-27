// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICommitmentFunds} from "./ICommitmentFunds.sol";
import {FeeTier, CommitmentConfig} from "../types/ConfigTypes.sol";
import {CommitmentExpiryStatus, CommitmentStatus} from "../types/CommitmentTypes.sol";

// ============ Structs ============

/// @notice Commitment data returned by view functions
struct CommitmentView {
    uint256 orgId;
    bytes32 postingRef;
    address creator;
    uint256 stake;
    uint256 feeAmount;
    uint256 activatedAt;
    uint256 stoppedAt;
    uint256 settledAt;
    uint8 feeTier;
    CommitmentStatus status;
}

/// @notice Application data returned by view functions
struct ApplicationView {
    address applicant;
    uint256 appliedAt;
    uint256 responseDeadline;
    uint256 respondedAt;
    bool isResponded;
}

// ============ Interface ============

/// @title IResponseCommitment
/// @notice Integration interface for the ResponseCommitment contract (excludes owner/governance functions).
interface IResponseCommitment {
    // ---- Events: Commitment Activation ----

    /// @notice Emitted when a new commitment is active
    event CommitmentActivated(
        uint256 indexed commitmentId,
        uint256 indexed orgId,
        address indexed creator,
        uint32 configVersion,
        uint256 stake,
        uint256 fee,
        uint8 responseDeadlineDays,
        bytes32 postingRef
    );

    // ---- Events: Application ----

    /// @notice Emitted when an applicant submits an application.
    event ApplicationSubmitted(
        bytes32 indexed applicationId, address indexed applicant, uint256 responseDeadline, bytes32 requestHash
    );

    // ---- Events: Response ----

    /// @notice Emitted when an application is responded to by a direct-call executor
    event ApplicationResponded(bytes32 indexed applicationId, address indexed executor, bytes32 responseId);

    // ---- Events: Commitment Lifecycle ----

    /// @notice Emitted when a commitment is stopped.
    event CommitmentStopped(uint256 indexed commitmentId, uint256 indexed orgId, address indexed actor);

    /// @notice Emitted when a commitment is settled and its organization stake is settled.
    event CommitmentSettled(
        uint256 indexed commitmentId,
        uint256 indexed orgId,
        address indexed actor,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 slashRate,
        uint256 stakeReturned,
        uint256 stakeSlashed
    );

    // ---- Events: Expired Settlement ----

    /// @notice Emitted when an expired commitment is settled by a direct-call executor
    event ExpiredCommitmentSettled(
        uint256 indexed commitmentId,
        uint256 indexed orgId,
        address indexed executor,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 slashRate,
        uint256 stakeReturned,
        uint256 stakeSlashed
    );

    // ---- Events: Config ----

    /// @notice Emitted when commitment config is updated
    event CommitmentConfigUpdated(uint32 indexed version, CommitmentConfig config, FeeTier[] tiers);

    // ---- Events: Rescue ----

    /// @notice Emitted when tokens are rescued from the contract
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    // ---- Commitment Activation ----

    /// @notice Create a new commitment after CommitmentFunds authorizes and bounds the org debit.
    /// @param orgId Organization ID that owns the commitment
    /// @param creator Org admin or commitment manager that initiated activation
    /// @param stakeAmount Amount of USDC to stake
    /// @param feeAmount Exact activation fee authorized by the creator
    /// @param activateData ABI-encoded activation parameters
    /// @return commitmentId The ID of the active commitment
    function activateCommitment(
        uint256 orgId,
        address creator,
        uint256 stakeAmount,
        uint256 feeAmount,
        bytes calldata activateData
    ) external returns (uint256 commitmentId);

    /// @notice Get commitment details
    /// @param commitmentId Commitment ID to query
    /// @return commitment Commitment data
    function commitment(uint256 commitmentId) external view returns (CommitmentView memory commitment);

    /// @notice Get the next commitment ID that will be assigned
    /// @return nextId The next commitment ID
    function nextCommitmentId() external view returns (uint256 nextId);

    // ---- Application ----

    /// @notice Submit an application authorized by an operator signature
    /// @param applicationId Unique non-zero application identifier
    /// @param responseDeadlineDays Response deadline days from operator signature
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature approving this application
    function submitApplication(
        bytes32 applicationId,
        uint8 responseDeadlineDays,
        uint256 expiry,
        bytes calldata signature
    ) external;

    /// @notice Get application details by applicationId
    /// @param applicationId Application ID to query
    /// @return application Application data
    function application(bytes32 applicationId) external view returns (ApplicationView memory application);

    // ---- Response ----

    /// @notice Record an application response as an authorized direct-call executor
    /// @param applicationId Application to respond to
    /// @param responseId Non-zero response identifier
    function recordApplicationResponse(bytes32 applicationId, bytes32 responseId) external;

    /// @notice Record multiple application responses as an authorized direct-call executor
    /// @param applicationIds Array of application IDs to respond to
    /// @param responseIds Array of response IDs (one per application)
    function recordApplicationResponses(bytes32[] calldata applicationIds, bytes32[] calldata responseIds) external;

    // ---- Commitment Lifecycle ----

    /// @notice Stop a commitment with an operator signature and org-side commitment-management authority.
    /// @param commitmentId Commitment to stop
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature approving this commitment stop
    function stopCommitment(uint256 commitmentId, uint256 keyNonce, uint256 expiry, bytes calldata signature) external;

    /// @notice Settle an active or stopped commitment with operator-attested counters and commitment-management authority.
    /// @param commitmentId Commitment to settle
    /// @param totalApplications Total applications (operator-attested)
    /// @param respondedApplications Responded applications (operator-attested)
    /// @param onTimeResponses On-time responses (operator-attested)
    /// @param counterSnapshotRoot Merkle root of the application counter snapshot
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature over the counters
    function settleCommitment(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external;

    // ---- Expired Settlement ----

    /// @notice Settle an expired commitment using operator-attested counters (executor only)
    /// @param commitmentId Commitment to settle
    /// @param totalApplications Total applications (operator-attested)
    /// @param respondedApplications Responded applications (operator-attested)
    /// @param onTimeResponses On-time responses (operator-attested)
    /// @param counterSnapshotRoot Merkle root of the application counter snapshot
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature over the counters
    function settleExpiredCommitment(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external;

    /// @notice Get expired settlement eligibility for a commitment
    /// @param commitmentId Commitment ID to check
    /// @return canSettle Whether the commitment can be expired-settled
    /// @return status Reason the commitment can or cannot be expired-settled
    function expiredSettlementInfo(uint256 commitmentId)
        external
        view
        returns (bool canSettle, CommitmentExpiryStatus status);

    // ---- Protocol Roles ----

    /// @notice Check if an address is an EIP-712 signing operator.
    function isOperator(address account) external view returns (bool);

    /// @notice List active EIP-712 signing operators.
    function operators() external view returns (address[] memory operators_);

    /// @notice Check if an address may submit privileged direct calls.
    function isExecutor(address account) external view returns (bool);

    /// @notice List active privileged direct-call executors.
    function executors() external view returns (address[] memory executors_);

    // ---- Config Views ----

    /// @notice Get current commitment configuration version.
    function currentConfigVersion() external view returns (uint32);

    /// @notice Get a commitment configuration by version.
    /// @param version Configuration version.
    function commitmentConfig(uint32 version) external view returns (CommitmentConfig memory);

    /// @notice Get one fee tier from a config version.
    /// @param version Configuration version.
    /// @param tier Fee tier index.
    function feeTier(uint32 version, uint8 tier) external view returns (FeeTier memory);

    /// @notice Get all fee tiers from a config version.
    /// @param version Configuration version.
    function feeTiers(uint32 version) external view returns (FeeTier[] memory tiers);

    /// @notice Get the latest commitment config.
    function currentCommitmentConfig() external view returns (CommitmentConfig memory);

    /// @notice Check whether an application ID has already been consumed.
    /// @param applicationId Application ID to check.
    function isApplicationIdUsed(bytes32 applicationId) external view returns (bool);

    /// @notice Returns the EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Contract that holds organization commitment funds and settles org stake.
    function commitmentFunds() external view returns (ICommitmentFunds);
}
