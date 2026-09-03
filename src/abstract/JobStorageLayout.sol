// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FeeTier, JobConfig} from "../types/ConfigTypes.sol";
import {OperatorAuthorizer} from "./OperatorAuthorizer.sol";
import {ExecutorRegistry} from "./ExecutorRegistry.sol";
import {ContentURIRegistry} from "./ContentURIRegistry.sol";
import {InvariantsLib} from "../libraries/InvariantsLib.sol";
import {Job, Application} from "../types/JobTypes.sol";

/// @title JobStorageLayout
/// @notice Shared plain storage layout for JobCommitment modules.
abstract contract JobStorageLayout is OperatorAuthorizer, ExecutorRegistry, ContentURIRegistry {
    // ============ Storage ============

    /// @notice Counter for job IDs (starts at 1).
    uint256 internal _nextJobId;

    /// @notice Mapping from job ID to job data.
    mapping(uint256 jobId => Job) internal _jobs;

    /// @notice Mapping from applicationId to application data (privacy: no jobId link).
    mapping(bytes32 applicationId => Application) internal _applications;

    /// @notice Mapping from applicationId to whether it has been used.
    mapping(bytes32 applicationId => bool) internal _usedApplicationIds;

    /// @notice Global counter: sum of all active applicant stakes.
    uint256 internal _totalApplicantStakes;

    /// @notice Versioned job configurations.
    mapping(uint32 configVersion => JobConfig) internal _jobConfigs;

    /// @notice Versioned fee tiers for each job configuration.
    mapping(uint32 configVersion => mapping(uint8 tier => FeeTier)) internal _feeTiers;

    /// @notice Current config version (incremented on each config update).
    uint32 internal _currentConfigVersion;

    /// @notice Exact applicant stake amount for new submissions.
    uint96 internal _applicantStakeAmount;

    // ============ Internal Helpers ============

    /// @notice Get a job by ID
    /// @param jobId Job ID
    /// @return job Job storage reference
    function _job(uint256 jobId) internal view returns (Job storage job) {
        return _jobs[jobId];
    }

    /// @notice Get an application by applicationId
    /// @param applicationId Application ID
    /// @return application Application storage reference
    function _application(bytes32 applicationId) internal view returns (Application storage application) {
        return _applications[applicationId];
    }

    /// @notice Check if an applicationId has been used
    /// @param applicationId Application ID
    /// @return used True if applicationId was already used
    function _isApplicationIdUsed(bytes32 applicationId) internal view returns (bool used) {
        return _usedApplicationIds[applicationId];
    }

    /// @notice Mark an applicationId as used
    /// @param applicationId Application ID
    function _markApplicationIdUsed(bytes32 applicationId) internal {
        _usedApplicationIds[applicationId] = true;
    }

    /// @notice Get job content URI
    /// @param jobId Job ID
    /// @return uri Content URI string
    function _contentURI(uint256 jobId) internal view returns (string storage uri) {
        return _contentURI(_jobURIKey(jobId));
    }

    /// @notice Set job content URI
    /// @param jobId Job ID
    /// @param uri Content URI string
    function _setContentURI(uint256 jobId, string memory uri) internal {
        _setContentURI(_jobURIKey(jobId), uri);
    }

    /// @notice Caller identity for modules that support a user actor.
    /// @dev Default returns the raw caller for standalone use (e.g. fuzz harnesses that inherit these modules
    ///      directly); the concrete JobCommitment overrides it with the ERC-2771 actor.
    function _actor() internal view virtual returns (address) {
        return msg.sender;
    }

    /// @notice Build the content key for a job.
    /// @param jobId Job ID.
    /// @return key Content URI storage key.
    function _jobURIKey(uint256 jobId) internal pure returns (bytes32 key) {
        return keccak256(abi.encode("JOB", jobId));
    }

    // ============ Invariant Check ============

    /// @notice Stake token for invariant check
    function _stakeTokenForInvariant() internal view virtual returns (IERC20);

    /// @dev Post-condition: token balance >= totalApplicantStakes.
    ///      Uses assert because violation indicates a contract accounting bug, not user input.
    function _checkApplicantStakeInvariant() internal view {
        InvariantsLib.assertBalanceGte(_stakeTokenForInvariant(), address(this), _totalApplicantStakes);
    }
}
