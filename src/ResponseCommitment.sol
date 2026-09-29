// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IResponseCommitment, CommitmentView, ApplicationView} from "./interfaces/IResponseCommitment.sol";
import {Errors} from "./Errors.sol";
import {FeeTier, CommitmentConfig} from "./types/ConfigTypes.sol";
import {ConfigValidationLib} from "./libraries/ConfigValidationLib.sol";
import {ICommitmentFunds} from "./interfaces/ICommitmentFunds.sol";
import {Application, CommitmentExpiryStatus, Commitment} from "./types/CommitmentTypes.sol";
import {CommitmentActivation} from "./abstract/CommitmentActivation.sol";
import {CommitmentApplication} from "./abstract/CommitmentApplication.sol";
import {CommitmentLifecycle} from "./abstract/CommitmentLifecycle.sol";
import {ResponseCommitmentStorageLayout} from "./abstract/ResponseCommitmentStorageLayout.sol";
import {OwnerControls} from "./abstract/OwnerControls.sol";
import {OperatorAuthorizer} from "./abstract/OperatorAuthorizer.sol";

/// @title ResponseCommitment
/// @notice Commitment and application state machine with separate authorization and execution roles.
/// @dev Immutable deployment that integrates with a specific CommitmentFunds.
/// @custom:security-contact security@comitium.co
contract ResponseCommitment is
    OwnerControls,
    CommitmentActivation,
    CommitmentApplication,
    CommitmentLifecycle,
    IResponseCommitment
{
    uint32 public constant commitmentVersion = 1;
    // ============ Immutables ============

    /// @notice The commitment funds contract.
    ICommitmentFunds public immutable commitmentFunds;

    // ============ Constructor ============

    /// @param commitmentFunds_ The CommitmentFunds contract
    /// @param owner_ The initial contract owner
    /// @param forwarder_ ERC-2771 forwarder for relayed commitment and application user operations.
    /// @param operator_ The initial EIP-712 signing operator address
    /// @param executor_ The initial privileged direct-call executor address
    /// @param commitmentConfig_ Initial commitment configuration (version 1)
    /// @param feeTiers_ Initial fee tiers for config version 1
    constructor(
        ICommitmentFunds commitmentFunds_,
        address owner_,
        address forwarder_,
        address operator_,
        address executor_,
        CommitmentConfig memory commitmentConfig_,
        FeeTier[] memory feeTiers_
    ) OwnerControls(owner_, forwarder_) OperatorAuthorizer("ResponseCommitment", "1", operator_) {
        if (address(commitmentFunds_) == address(0)) revert Errors.ZeroAddress();

        commitmentFunds = commitmentFunds_;

        _addExecutorChecked(executor_, trustedForwarder());

        ConfigValidationLib.validateCommitmentConfig(commitmentConfig_);
        ConfigValidationLib.validateFeeTiers(feeTiers_);
        _currentConfigVersion = 1;
        _storeCommitmentConfig(1, commitmentConfig_, feeTiers_);
    }

    // ============ Internal Overrides ============

    /// @dev Provides commitment funds for lifecycle settlement.
    function _commitmentFunds() internal view override(CommitmentLifecycle) returns (ICommitmentFunds) {
        return commitmentFunds;
    }

    /// @dev Use the ERC-2771 actor only where `_actor()` is explicitly called.
    function _actor() internal view override(OwnerControls, ResponseCommitmentStorageLayout) returns (address) {
        return OwnerControls._actor();
    }

    /// @notice Returns the EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _operatorDomainSeparator();
    }

    // ============ Public Functions ============

    /// @inheritdoc IResponseCommitment
    function activateCommitment(
        uint256 orgId,
        address creator,
        uint256 stakeAmount,
        uint256 feeAmount,
        bytes calldata activateData
    ) external whenNotPaused nonReentrant returns (uint256 commitmentId) {
        if (msg.sender != address(commitmentFunds)) {
            revert Errors.NotCommitmentFunds(msg.sender);
        }

        (uint8 selectedFeeTier, bytes32 postingRef, uint256 keyNonce, uint256 expiry, bytes memory signature) =
            abi.decode(activateData, (uint8, bytes32, uint256, uint256, bytes));

        return _activateCommitment(
            orgId, stakeAmount, selectedFeeTier, feeAmount, postingRef, creator, keyNonce, expiry, signature
        );
    }

    /// @inheritdoc IResponseCommitment
    function submitApplication(
        bytes32 applicationId,
        uint8 responseDeadlineDays,
        uint256 expiry,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        _submitApplication(applicationId, responseDeadlineDays, expiry, signature, keccak256(_actorCalldata()));
    }

    /// @inheritdoc IResponseCommitment
    function recordApplicationResponse(bytes32 applicationId, bytes32 responseId) external nonReentrant onlyExecutor {
        _recordApplicationResponse(applicationId, responseId);
    }

    /// @inheritdoc IResponseCommitment
    function recordApplicationResponses(bytes32[] calldata applicationIds, bytes32[] calldata responseIds)
        external
        nonReentrant
        onlyExecutor
    {
        _recordApplicationResponses(applicationIds, responseIds);
    }

    /// @inheritdoc IResponseCommitment
    function stopCommitment(uint256 commitmentId, uint256 keyNonce, uint256 expiry, bytes calldata signature)
        external
        whenNotPaused
        nonReentrant
    {
        _stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    /// @inheritdoc IResponseCommitment
    function settleCommitment(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant {
        _settleCommitment(
            commitmentId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            keyNonce,
            expiry,
            signature
        );
    }

    /// @inheritdoc IResponseCommitment
    function settleExpiredCommitment(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant onlyExecutor {
        _settleExpiredCommitment(
            commitmentId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            keyNonce,
            expiry,
            signature
        );
    }

    // ============ Admin Functions ============

    /// @notice Add an EIP-712 signing operator.
    function addOperator(address operator) external onlyOwner {
        _addOperatorChecked(operator);
    }

    /// @notice Remove an EIP-712 signing operator.
    function removeOperator(address operator) external onlyOwner {
        _removeOperator(operator);
    }

    /// @notice Add a privileged direct-call executor.
    function addExecutor(address executor) external onlyOwner {
        _addExecutorChecked(executor, trustedForwarder());
    }

    /// @notice Remove a privileged direct-call executor.
    function removeExecutor(address executor) external onlyOwner {
        _removeExecutor(executor);
    }

    /// @notice Set a new commitment configuration version.
    /// @dev Creates a new version. Existing commitments retain their creation-time version.
    /// @param config The new commitment configuration.
    /// @param tiers Fee tiers for the new commitment configuration.
    function setCommitmentConfig(CommitmentConfig calldata config, FeeTier[] calldata tiers) external onlyOwner {
        ConfigValidationLib.validateCommitmentConfig(config);
        ConfigValidationLib.validateFeeTiers(tiers);

        uint32 version = ++_currentConfigVersion;
        _storeCommitmentConfig(version, config, tiers);

        emit CommitmentConfigUpdated(version, config, tiers);
    }

    /// @dev Emits the commitment rescue event after the shared rescue transfer succeeds.
    function _emitTokensRescued(address token, address to, uint256 amount) internal override {
        emit TokensRescued(token, to, amount);
    }

    // ============ View Functions ============

    /// @inheritdoc IResponseCommitment
    function commitment(uint256 commitmentId) external view returns (CommitmentView memory commitmentView) {
        Commitment storage commitmentData = _commitment(commitmentId);

        return CommitmentView({
            orgId: commitmentData.orgId,
            postingRef: commitmentData.postingRef,
            creator: commitmentData.creator,
            stake: commitmentData.stake,
            feeAmount: commitmentData.feeAmount,
            activatedAt: commitmentData.activatedAt,
            stoppedAt: commitmentData.stoppedAt,
            settledAt: commitmentData.settledAt,
            feeTier: commitmentData.feeTier,
            status: commitmentData.status
        });
    }

    /// @inheritdoc IResponseCommitment
    function application(bytes32 applicationId) external view returns (ApplicationView memory applicationView) {
        Application storage applicationData = _application(applicationId);

        return ApplicationView({
            applicant: applicationData.applicant,
            appliedAt: applicationData.appliedAt,
            responseDeadline: applicationData.responseDeadline,
            respondedAt: applicationData.respondedAt,
            isResponded: applicationData.isResponded
        });
    }

    /// @inheritdoc IResponseCommitment
    function expiredSettlementInfo(uint256 commitmentId)
        external
        view
        returns (bool canSettle, CommitmentExpiryStatus status)
    {
        return _expiredSettlementInfo(commitmentId);
    }

    /// @inheritdoc IResponseCommitment
    function nextCommitmentId() external view returns (uint256 nextId) {
        return _nextCommitmentId + 1;
    }

    /// @inheritdoc IResponseCommitment
    function isOperator(address account) external view returns (bool) {
        return _isOperator(account);
    }

    /// @inheritdoc IResponseCommitment
    function operators() external view returns (address[] memory operators_) {
        return _operatorsList();
    }

    /// @inheritdoc IResponseCommitment
    function isExecutor(address account) external view returns (bool) {
        return _isExecutor(account);
    }

    /// @inheritdoc IResponseCommitment
    function executors() external view returns (address[] memory executors_) {
        return _executorsList();
    }

    /// @notice Check if an application ID has been used
    function isApplicationIdUsed(bytes32 applicationId) external view returns (bool) {
        return _isApplicationIdUsed(applicationId);
    }

    /// @notice Get current economic config version
    function currentConfigVersion() external view returns (uint32) {
        return _currentConfigVersion;
    }

    /// @notice Get commitment config by version.
    function commitmentConfig(uint32 version) external view returns (CommitmentConfig memory) {
        return _commitmentConfigs[version];
    }

    /// @notice Get a fee tier for a commitment config version.
    function feeTier(uint32 version, uint8 tier) external view returns (FeeTier memory) {
        return _feeTiers[version][tier];
    }

    /// @notice Get all fee tiers for a commitment config version.
    function feeTiers(uint32 version) external view returns (FeeTier[] memory tiers) {
        uint8 tierCount = _commitmentConfigs[version].tierCount;
        tiers = new FeeTier[](tierCount);

        for (uint8 i = 0; i < tierCount; i++) {
            tiers[i] = _feeTiers[version][i];
        }
    }

    /// @notice Get current (latest) commitment config.
    function currentCommitmentConfig() external view returns (CommitmentConfig memory) {
        return _commitmentConfigs[_currentConfigVersion];
    }

    /// @notice Store a commitment configuration version and its fee tiers.
    /// @param version Config version key.
    /// @param config Commitment configuration to store.
    /// @param tiers Fee tiers matching config.tierCount.
    function _storeCommitmentConfig(uint32 version, CommitmentConfig memory config, FeeTier[] memory tiers) private {
        if (config.tierCount != tiers.length) revert Errors.ConfigValueOutOfRange("tierCount");

        _commitmentConfigs[version] = config;

        for (uint8 tier = 0; tier < config.tierCount; tier++) {
            _feeTiers[version][tier] = tiers[tier];
        }
    }
}
