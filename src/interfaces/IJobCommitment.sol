// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IJobFunds} from "./IJobFunds.sol";
import {FeeTier, JobConfig} from "../types/ConfigTypes.sol";
import {JobExpiryStatus, JobStatus} from "../types/JobTypes.sol";

// ============ Structs ============

/// @notice Job data returned by view functions
struct JobView {
    uint256 orgId;
    address creator;
    uint256 stake;
    uint256 feeAmount;
    uint256 createdAt;
    uint256 unpublishedAt;
    uint256 closedAt;
    uint8 feeTier;
    JobStatus status;
    bool orgStakeSettled;
    string contentURI;
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

/// @title IJobCommitment
/// @notice Integration interface for the JobCommitment contract (excludes owner/governance functions).
interface IJobCommitment {
    // ---- Events: Job Publication ----

    /// @notice Emitted when a new job is published
    event JobPublished(
        uint256 indexed jobId,
        uint256 indexed orgId,
        address indexed creator,
        uint32 configVersion,
        uint256 stake,
        uint256 fee,
        uint8 responseDeadlineDays,
        string contentURI
    );

    // ---- Events: Application ----

    /// @notice Emitted when an applicant submits an application.
    event ApplicationSubmitted(
        bytes32 indexed applicationId, address indexed applicant, uint256 responseDeadline, bytes32 requestHash
    );

    // ---- Events: Response ----

    /// @notice Emitted when an application is responded to by a direct-call executor
    event ApplicationResponded(bytes32 indexed applicationId, address indexed executor, bytes32 responseId);

    // ---- Events: Job Lifecycle ----

    /// @notice Emitted when a job is unpublished.
    event JobUnpublished(uint256 indexed jobId, uint256 indexed orgId, address indexed actor);

    /// @notice Emitted when a job is closed and its organization stake is settled.
    event JobClosed(
        uint256 indexed jobId,
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

    /// @notice Emitted when published job metadata URI is updated.
    event JobContentURIUpdated(
        uint256 indexed jobId, uint256 indexed orgId, address indexed updater, string contentURI
    );

    // ---- Events: Expired Settlement ----

    /// @notice Emitted when an expired job is settled by a direct-call executor
    event JobExpiredSettled(
        uint256 indexed jobId,
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

    /// @notice Emitted when job config is updated
    event JobConfigUpdated(uint32 indexed version, JobConfig config, FeeTier[] tiers);

    // ---- Events: Rescue ----

    /// @notice Emitted when tokens are rescued from the contract
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    // ---- Job Publication ----

    /// @notice Create a new job after JobFunds authorizes and bounds the org debit.
    /// @param orgId Organization ID that owns the job
    /// @param creator Authorized org manager that initiated publication
    /// @param stakeAmount Amount of USDC to stake
    /// @param feeAmount Exact publishing fee authorized by the creator
    /// @param publishData ABI-encoded publication parameters
    /// @return jobId The ID of the published job
    function createJob(
        uint256 orgId,
        address creator,
        uint256 stakeAmount,
        uint256 feeAmount,
        bytes calldata publishData
    ) external returns (uint256 jobId);

    /// @notice Get job details
    /// @param jobId Job ID to query
    /// @return job Job data
    function job(uint256 jobId) external view returns (JobView memory job);

    /// @notice Get the next job ID that will be assigned
    /// @return nextId The next job ID
    function nextJobId() external view returns (uint256 nextId);

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

    // ---- Job Lifecycle ----

    /// @notice Unpublish a job with an operator signature and org-side job-management authority.
    /// @param jobId Job to unpublish
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature approving this job unpublish
    function unpublishJob(uint256 jobId, uint256 keyNonce, uint256 expiry, bytes calldata signature) external;

    /// @notice Close a published or unpublished job with operator-attested counters and job-management authority.
    /// @param jobId Job to close
    /// @param totalApplications Total applications (operator-attested)
    /// @param respondedApplications Responded applications (operator-attested)
    /// @param onTimeResponses On-time responses (operator-attested)
    /// @param counterSnapshotRoot Merkle root of the application counter snapshot
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature over the counters
    function closeJob(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external;

    /// @notice Update published job metadata URI with an operator signature and org-side job-management authority.
    /// @param jobId Job to update
    /// @param contentURI New IPFS URI with job metadata
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature approving this metadata update
    function updateJobContentURI(
        uint256 jobId,
        string calldata contentURI,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external;

    // ---- Expired Settlement ----

    /// @notice Settle an expired job using operator-attested counters (executor only)
    /// @param jobId Job to settle
    /// @param totalApplications Total applications (operator-attested)
    /// @param respondedApplications Responded applications (operator-attested)
    /// @param onTimeResponses On-time responses (operator-attested)
    /// @param counterSnapshotRoot Merkle root of the application counter snapshot
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature over the counters
    function settleExpiredJob(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external;

    /// @notice Get expired settlement eligibility for a job
    /// @param jobId Job ID to check
    /// @return canSettle Whether the job can be expired-settled
    /// @return status Reason the job can or cannot be expired-settled
    function expiredSettlementInfo(uint256 jobId) external view returns (bool canSettle, JobExpiryStatus status);

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

    /// @notice Get current job configuration version.
    function currentConfigVersion() external view returns (uint32);

    /// @notice Get a job configuration by version.
    /// @param version Configuration version.
    function jobConfig(uint32 version) external view returns (JobConfig memory);

    /// @notice Get one fee tier from a config version.
    /// @param version Configuration version.
    /// @param tier Fee tier index.
    function feeTier(uint32 version, uint8 tier) external view returns (FeeTier memory);

    /// @notice Get all fee tiers from a config version.
    /// @param version Configuration version.
    function feeTiers(uint32 version) external view returns (FeeTier[] memory tiers);

    /// @notice Get the latest job config.
    function currentJobConfig() external view returns (JobConfig memory);

    /// @notice Check whether an application ID has already been consumed.
    /// @param applicationId Application ID to check.
    function isApplicationIdUsed(bytes32 applicationId) external view returns (bool);

    /// @notice Returns the EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Contract that holds organization job funds and settles org stake.
    function jobFunds() external view returns (IJobFunds);
}
