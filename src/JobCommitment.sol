// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IJobCommitment, JobView, ApplicationView, StakeReturnInfo} from "./interfaces/IJobCommitment.sol";
import {Errors} from "./Errors.sol";
import {FeeTier, JobConfig} from "./types/ConfigTypes.sol";
import {ConfigValidationLib} from "./libraries/ConfigValidationLib.sol";
import {IJobFunds} from "./interfaces/IJobFunds.sol";
import {Application, JobExpiryStatus, Job} from "./types/JobTypes.sol";
import {JobPublish} from "./abstract/JobPublish.sol";
import {JobApplication} from "./abstract/JobApplication.sol";
import {JobLifecycle} from "./abstract/JobLifecycle.sol";
import {JobStorageLayout} from "./abstract/JobStorageLayout.sol";
import {OwnerControls} from "./abstract/OwnerControls.sol";
import {OperatorAuthorizer} from "./abstract/OperatorAuthorizer.sol";

/// @title JobCommitment
/// @notice Job and application state machine with separate authorization and execution roles.
/// @dev Immutable deployment that integrates with a specific JobFunds.
/// @custom:security-contact security@comitium.co
contract JobCommitment is OwnerControls, JobPublish, JobApplication, JobLifecycle, IJobCommitment {
    uint32 public constant commitmentVersion = 1;
    // ============ Immutables ============

    /// @notice The stake token (USDC)
    IERC20 public immutable stakeToken;

    /// @notice The job funds contract.
    IJobFunds public immutable jobFunds;

    // ============ Constructor ============

    /// @param stakeToken_ The stake token address (USDC)
    /// @param jobFunds_ The JobFunds contract
    /// @param owner_ The initial contract owner
    /// @param forwarder_ ERC-2771 forwarder for relayed job and application user operations.
    /// @param operator_ The initial EIP-712 signing operator address
    /// @param executor_ The initial privileged direct-call executor address
    /// @param jobConfig_ Initial job configuration (version 1)
    /// @param feeTiers_ Initial fee tiers for config version 1
    /// @param applicantStakeAmount_ Exact applicant stake amount
    constructor(
        IERC20 stakeToken_,
        IJobFunds jobFunds_,
        address owner_,
        address forwarder_,
        address operator_,
        address executor_,
        JobConfig memory jobConfig_,
        FeeTier[] memory feeTiers_,
        uint96 applicantStakeAmount_
    ) OwnerControls(owner_, forwarder_) OperatorAuthorizer("JobCommitment", "1", operator_) {
        if (address(stakeToken_) == address(0)) revert Errors.ZeroAddress();
        if (address(jobFunds_) == address(0)) revert Errors.ZeroAddress();

        stakeToken = stakeToken_;
        jobFunds = jobFunds_;

        _addExecutorChecked(executor_);

        ConfigValidationLib.validateJobConfig(jobConfig_);
        ConfigValidationLib.validateFeeTiers(feeTiers_);
        ConfigValidationLib.validateApplicantStakeAmount(applicantStakeAmount_);

        _currentConfigVersion = 1;
        _storeJobConfig(1, jobConfig_, feeTiers_);
        _applicantStakeAmount = applicantStakeAmount_;
    }

    // ============ Internal Overrides ============

    /// @dev Provides stake token to base contracts
    function _stakeToken() internal view override(JobApplication) returns (IERC20) {
        return stakeToken;
    }

    /// @dev Provides stake token for balance invariant check
    function _stakeTokenForInvariant() internal view override returns (IERC20) {
        return stakeToken;
    }

    /// @dev Provides job funds for org authorization and lifecycle settlement.
    function _jobFunds() internal view override(JobPublish, JobLifecycle) returns (IJobFunds) {
        return jobFunds;
    }

    /// @dev Use the ERC-2771 actor only where `_actor()` is explicitly called.
    function _actor() internal view override(OwnerControls, JobStorageLayout) returns (address) {
        return OwnerControls._actor();
    }

    /// @notice Returns the EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _operatorDomainSeparator();
    }

    // ============ Public Functions ============

    /// @inheritdoc IJobCommitment
    function createJob(
        uint256 orgId,
        address creator,
        uint256 stakeAmount,
        uint256 feeAmount,
        bytes calldata publishData
    ) external whenNotPaused nonReentrant returns (uint256 jobId) {
        if (msg.sender != address(jobFunds)) revert Errors.NotJobFunds(msg.sender);

        (uint8 selectedFeeTier, string memory contentURI, uint256 keyNonce, uint256 expiry, bytes memory signature) =
            abi.decode(publishData, (uint8, string, uint256, uint256, bytes));

        return
            _publishJob(
                orgId, stakeAmount, selectedFeeTier, feeAmount, contentURI, creator, keyNonce, expiry, signature
            );
    }

    /// @inheritdoc IJobCommitment
    function submitApplication(
        bytes32 applicationId,
        uint96 stake,
        uint8 responseDeadlineDays,
        uint256 expiry,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        _submitApplication(applicationId, stake, responseDeadlineDays, expiry, signature, keccak256(_actorCalldata()));
    }

    /// @inheritdoc IJobCommitment
    function recordApplicationResponse(bytes32 applicationId, bytes32 responseId) external nonReentrant onlyExecutor {
        _recordApplicationResponse(applicationId, responseId);
    }

    /// @inheritdoc IJobCommitment
    function recordApplicationResponses(bytes32[] calldata applicationIds, bytes32[] calldata responseIds)
        external
        nonReentrant
        onlyExecutor
    {
        _recordApplicationResponses(applicationIds, responseIds);
    }

    /// @inheritdoc IJobCommitment
    function unpublishJob(uint256 jobId, uint256 keyNonce, uint256 expiry, bytes calldata signature)
        external
        whenNotPaused
        nonReentrant
    {
        _unpublishJob(jobId, keyNonce, expiry, signature);
    }

    /// @inheritdoc IJobCommitment
    function closeJob(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant {
        _closeJob(
            jobId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            keyNonce,
            expiry,
            signature
        );
    }

    /// @inheritdoc IJobCommitment
    function updateJobContentURI(
        uint256 jobId,
        string calldata contentURI,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        _updateJobContentURI(jobId, contentURI, keyNonce, expiry, signature);
    }

    /// @inheritdoc IJobCommitment
    function withdrawStake(bytes32 applicationId) external nonReentrant {
        _withdrawStake(applicationId);
    }

    /// @inheritdoc IJobCommitment
    function withdrawStakes(bytes32[] calldata applicationIds)
        external
        nonReentrant
        returns (uint16 returnedCount, uint16 skippedCount, uint256 totalReturned)
    {
        return _withdrawStakes(applicationIds);
    }

    /// @inheritdoc IJobCommitment
    function settleExpiredJob(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external nonReentrant onlyExecutor {
        _settleExpiredJob(
            jobId,
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
        if (_isExecutor(operator)) revert Errors.ProtocolRoleConflict(operator);

        _addOperator(operator);
    }

    /// @notice Remove an EIP-712 signing operator.
    function removeOperator(address operator) external onlyOwner {
        _removeOperator(operator);
    }

    /// @notice Add a privileged direct-call executor.
    function addExecutor(address executor) external onlyOwner {
        _addExecutorChecked(executor);
    }

    /// @notice Remove a privileged direct-call executor.
    function removeExecutor(address executor) external onlyOwner {
        _removeExecutor(executor);
    }

    /// @notice Set a new job configuration version.
    /// @dev Creates a new version. Existing jobs retain their creation-time version.
    /// @param config The new job configuration.
    /// @param tiers Fee tiers for the new job configuration.
    function setJobConfig(JobConfig calldata config, FeeTier[] calldata tiers) external onlyOwner {
        ConfigValidationLib.validateJobConfig(config);
        ConfigValidationLib.validateFeeTiers(tiers);

        uint32 version = ++_currentConfigVersion;
        _storeJobConfig(version, config, tiers);

        emit JobConfigUpdated(version, config, tiers);
    }

    /// @notice Set the exact applicant stake amount for new submissions.
    /// @param newAmount New exact applicant stake amount.
    function setApplicantStakeAmount(uint96 newAmount) external onlyOwner {
        ConfigValidationLib.validateApplicantStakeAmount(newAmount);

        if (newAmount == _applicantStakeAmount) revert Errors.ApplicantStakeAmountUnchanged(newAmount);

        _applicantStakeAmount = newAmount;

        emit ApplicantStakeAmountUpdated(newAmount);
    }

    /// @dev For stakeToken, only balance above totalApplicantStakes can be rescued.
    function _validateTokenRescue(address token, uint256 amount) internal view override {
        if (token == address(stakeToken)) {
            uint256 balance = stakeToken.balanceOf(address(this));
            uint256 surplus = balance > _totalApplicantStakes ? balance - _totalApplicantStakes : 0;

            if (amount > surplus) revert Errors.RescueExceedsSurplus(amount, surplus);
        }
    }

    /// @dev Emits the commitment rescue event after the shared rescue transfer succeeds.
    function _emitTokensRescued(address token, address to, uint256 amount) internal override {
        emit TokensRescued(token, to, amount);
    }

    // ============ View Functions ============

    /// @inheritdoc IJobCommitment
    function job(uint256 jobId) external view returns (JobView memory jobView) {
        Job storage jobData = _job(jobId);

        return JobView({
            orgId: jobData.orgId,
            creator: jobData.creator,
            stake: jobData.stake,
            feeAmount: jobData.feeAmount,
            createdAt: jobData.createdAt,
            unpublishedAt: jobData.unpublishedAt,
            closedAt: jobData.closedAt,
            feeTier: jobData.feeTier,
            status: jobData.status,
            orgStakeSettled: jobData.orgStakeSettled,
            contentURI: _contentURI(jobId)
        });
    }

    /// @inheritdoc IJobCommitment
    function application(bytes32 applicationId) external view returns (ApplicationView memory applicationView) {
        Application storage applicationData = _application(applicationId);

        return ApplicationView({
            applicant: applicationData.applicant,
            stake: applicationData.stake,
            appliedAt: applicationData.appliedAt,
            responseDeadline: applicationData.responseDeadline,
            respondedAt: applicationData.respondedAt,
            isResponded: applicationData.isResponded,
            stakeWithdrawn: applicationData.stakeWithdrawn
        });
    }

    /// @inheritdoc IJobCommitment
    function stakeReturnInfo(bytes32 applicationId) external view returns (StakeReturnInfo memory info) {
        return _stakeReturnInfo(applicationId);
    }

    /// @inheritdoc IJobCommitment
    function expiredSettlementInfo(uint256 jobId) external view returns (bool canSettle, JobExpiryStatus status) {
        return _expiredSettlementInfo(jobId);
    }

    /// @inheritdoc IJobCommitment
    function nextJobId() external view returns (uint256 nextId) {
        return _nextJobId + 1;
    }

    /// @inheritdoc IJobCommitment
    function isOperator(address account) external view returns (bool) {
        return _isOperator(account);
    }

    /// @inheritdoc IJobCommitment
    function operators() external view returns (address[] memory operators_) {
        return _operatorsList();
    }

    /// @inheritdoc IJobCommitment
    function isExecutor(address account) external view returns (bool) {
        return _isExecutor(account);
    }

    /// @inheritdoc IJobCommitment
    function executors() external view returns (address[] memory executors_) {
        return _executorsList();
    }

    /// @notice Check if an application ID has been used
    function isApplicationIdUsed(bytes32 applicationId) external view returns (bool) {
        return _isApplicationIdUsed(applicationId);
    }

    /// @inheritdoc IJobCommitment
    function totalApplicantStakes() external view returns (uint256 total) {
        return _totalApplicantStakes;
    }

    /// @notice Get current economic config version
    function currentConfigVersion() external view returns (uint32) {
        return _currentConfigVersion;
    }

    /// @notice Get job config by version.
    function jobConfig(uint32 version) external view returns (JobConfig memory) {
        return _jobConfigs[version];
    }

    /// @notice Get a fee tier for a job config version.
    function feeTier(uint32 version, uint8 tier) external view returns (FeeTier memory) {
        return _feeTiers[version][tier];
    }

    /// @notice Get all fee tiers for a job config version.
    function feeTiers(uint32 version) external view returns (FeeTier[] memory tiers) {
        uint8 tierCount = _jobConfigs[version].tierCount;
        tiers = new FeeTier[](tierCount);

        for (uint8 i = 0; i < tierCount; i++) {
            tiers[i] = _feeTiers[version][i];
        }
    }

    /// @notice Get current (latest) job config.
    function currentJobConfig() external view returns (JobConfig memory) {
        return _jobConfigs[_currentConfigVersion];
    }

    /// @notice Get the exact applicant stake amount for new submissions.
    function applicantStakeAmount() external view returns (uint96) {
        return _applicantStakeAmount;
    }

    /// @notice Store a job configuration version and its fee tiers.
    /// @param version Config version key.
    /// @param config Job configuration to store.
    /// @param tiers Fee tiers matching config.tierCount.
    function _storeJobConfig(uint32 version, JobConfig memory config, FeeTier[] memory tiers) private {
        if (config.tierCount != tiers.length) revert Errors.ConfigValueOutOfRange("tierCount");

        _jobConfigs[version] = config;

        for (uint8 tier = 0; tier < config.tierCount; tier++) {
            _feeTiers[version][tier] = tiers[tier];
        }
    }

    function _addExecutorChecked(address executor) private {
        if (_isOperator(executor) || executor == trustedForwarder()) revert Errors.ProtocolRoleConflict(executor);

        _addExecutor(executor);
    }
}
