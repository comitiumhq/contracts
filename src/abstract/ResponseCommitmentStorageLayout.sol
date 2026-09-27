// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {FeeTier, CommitmentConfig} from "../types/ConfigTypes.sol";
import {OperatorAuthorizer} from "./OperatorAuthorizer.sol";
import {ExecutorRegistry} from "./ExecutorRegistry.sol";
import {Commitment, Application} from "../types/CommitmentTypes.sol";

/// @title ResponseCommitmentStorageLayout
/// @notice Shared plain storage layout for ResponseCommitment modules.
abstract contract ResponseCommitmentStorageLayout is OperatorAuthorizer, ExecutorRegistry {
    // ============ Storage ============

    uint256 internal _nextCommitmentId;

    mapping(uint256 commitmentId => Commitment) internal _commitments;

    /// @dev The contract stores no application-to-commitment mapping.
    mapping(bytes32 applicationId => Application) internal _applications;

    mapping(bytes32 applicationId => bool) internal _usedApplicationIds;

    mapping(uint32 configVersion => CommitmentConfig) internal _commitmentConfigs;

    mapping(uint32 configVersion => mapping(uint8 tier => FeeTier)) internal _feeTiers;

    uint32 internal _currentConfigVersion;

    // ============ Internal Helpers ============

    function _commitment(uint256 commitmentId) internal view returns (Commitment storage commitment_) {
        return _commitments[commitmentId];
    }

    function _application(bytes32 applicationId) internal view returns (Application storage application) {
        return _applications[applicationId];
    }

    function _isApplicationIdUsed(bytes32 applicationId) internal view returns (bool used) {
        return _usedApplicationIds[applicationId];
    }

    function _markApplicationIdUsed(bytes32 applicationId) internal {
        _usedApplicationIds[applicationId] = true;
    }

    /// @notice Caller identity for modules that support a user actor.
    /// @dev Default returns the raw caller for standalone use (e.g. fuzz harnesses that inherit these modules
    ///      directly); the concrete ResponseCommitment overrides it with the ERC-2771 actor.
    function _actor() internal view virtual returns (address) {
        return msg.sender;
    }
}
