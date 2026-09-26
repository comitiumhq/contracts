// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FeeTier, JobConfig} from "../types/ConfigTypes.sol";
import {OperatorAuthorizer} from "./OperatorAuthorizer.sol";
import {ExecutorRegistry} from "./ExecutorRegistry.sol";
import {Job, Application} from "../types/JobTypes.sol";

/// @title JobStorageLayout
/// @notice Shared plain storage layout for JobCommitment modules.
abstract contract JobStorageLayout is OperatorAuthorizer, ExecutorRegistry {
    // ============ Storage ============

    /// @notice Counter for job IDs (starts at 1).
    uint256 internal _nextJobId;

    /// @notice Mapping from job ID to job data.
    mapping(uint256 jobId => Job) internal _jobs;

    /// @dev The contract stores no application-to-job mapping.
    mapping(bytes32 applicationId => Application) internal _applications;

    /// @notice Mapping from applicationId to whether it has been used.
    mapping(bytes32 applicationId => bool) internal _usedApplicationIds;

    /// @notice Versioned job configurations.
    mapping(uint32 configVersion => JobConfig) internal _jobConfigs;

    /// @notice Versioned fee tiers for each job configuration.
    mapping(uint32 configVersion => mapping(uint8 tier => FeeTier)) internal _feeTiers;

    /// @notice Current config version (incremented on each config update).
    uint32 internal _currentConfigVersion;

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

    /// @notice Caller identity for modules that support a user actor.
    /// @dev Default returns the raw caller for standalone use (e.g. fuzz harnesses that inherit these modules
    ///      directly); the concrete JobCommitment overrides it with the ERC-2771 actor.
    function _actor() internal view virtual returns (address) {
        return msg.sender;
    }
}
