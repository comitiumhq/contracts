// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IOrgRegistry, OrgView, PendingOrgTreasuryView} from "./interfaces/IOrgRegistry.sol";
import {Errors} from "./Errors.sol";
import {Org, TreasuryTransfer} from "./types/OrgTypes.sol";
import {OrgLifecycle} from "./abstract/OrgLifecycle.sol";
import {OrgStorageLayout} from "./abstract/OrgStorageLayout.sol";
import {OwnerControls} from "./abstract/OwnerControls.sol";
import {OperatorAuthorizer} from "./abstract/OperatorAuthorizer.sol";
import {OrgAuthorizationLib} from "./libraries/OrgAuthorizationLib.sol";

/// @title OrgRegistry
/// @notice Manages Comitium organization identity, admins, treasury, and metadata.
/// @dev Immutable deployment that owns organization identity and metadata only.
/// @custom:security-contact security@comitium.co
contract OrgRegistry is OwnerControls, OrgLifecycle, IOrgRegistry {
    // ============ Constructor ============

    /// @param owner_ The initial contract owner
    /// @param forwarder_ ERC-2771 forwarder for relayed organization user operations.
    /// @param operator_ The initial EIP-712 signing operator address
    /// @param executor_ The initial privileged direct-call executor address
    constructor(address owner_, address forwarder_, address operator_, address executor_)
        OwnerControls(owner_, forwarder_)
        OperatorAuthorizer("OrgRegistry", "1", operator_)
    {
        _addExecutorChecked(executor_, trustedForwarder());
    }

    /// @dev Use the ERC-2771 actor only where `_actor()` is explicitly called.
    function _actor() internal view override(OwnerControls, OrgStorageLayout) returns (address) {
        return OwnerControls._actor();
    }

    // ============ Organization Lifecycle ============

    /// @inheritdoc IOrgRegistry
    function createOrg(address creator, bytes32 domainHash, uint256 keyNonce, uint256 expiry, bytes calldata signature)
        external
        whenNotPaused
        onlyExecutor
        returns (uint256 orgId)
    {
        return _createOrg(creator, domainHash, keyNonce, expiry, signature, keccak256(msg.data));
    }

    /// @inheritdoc IOrgRegistry
    function updateOrgDomain(
        uint256 orgId,
        bytes32 currentDomainHash,
        bytes32 newDomainHash,
        address updater,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external onlyExecutor {
        _updateOrgDomain(
            orgId, currentDomainHash, newDomainHash, updater, keyNonce, expiry, signature, keccak256(msg.data)
        );
    }

    // ============ Owner Functions ============

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

    /// @inheritdoc IOrgRegistry
    function updateContentURI(
        uint256 orgId,
        string calldata contentURI,
        address updater,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external onlyExecutor {
        if (bytes(contentURI).length == 0) revert Errors.EmptyContentURI();
        if (updater == address(0)) revert Errors.ZeroAddress();

        _requireOrg(orgId);

        bytes32 structHash =
            OrgAuthorizationLib.hashOrgContentUpdate(orgId, keccak256(bytes(contentURI)), updater, keyNonce, expiry);

        _consumeOperatorAuthorization(
            structHash, OrgAuthorizationLib.NONCE_SCOPE_ORG_CONTENT_UPDATE, keyNonce, expiry, signature
        );
        _setContentURI(orgId, contentURI);

        emit ContentURIUpdated(orgId, updater, contentURI);
    }

    /// @inheritdoc IOrgRegistry
    function setOrgAdmin(uint256 orgId, address account, bool active) external {
        _setOrgAdmin(orgId, account, active);
    }

    /// @inheritdoc IOrgRegistry
    function proposeOrgTreasuryTransfer(uint256 orgId, address newTreasury) external {
        _proposeOrgTreasuryTransfer(orgId, newTreasury);
    }

    /// @inheritdoc IOrgRegistry
    function acceptOrgTreasuryTransfer(uint256 orgId) external {
        _acceptOrgTreasuryTransfer(orgId);
    }

    /// @inheritdoc IOrgRegistry
    function finalizeOrgTreasuryTransfer(uint256 orgId) external {
        _finalizeOrgTreasuryTransfer(orgId);
    }

    /// @inheritdoc IOrgRegistry
    function cancelOrgTreasuryTransfer(uint256 orgId) external {
        _cancelOrgTreasuryTransfer(orgId);
    }

    /// @dev Emits the registry rescue event after the shared rescue transfer succeeds.
    function _emitTokensRescued(address token, address to, uint256 amount) internal override {
        emit TokensRescued(token, to, amount);
    }

    // ============ View Functions ============

    /// @inheritdoc IOrgRegistry
    function org(uint256 orgId) external view returns (OrgView memory orgView) {
        Org storage orgData = _requireOrg(orgId);

        return OrgView({treasury: orgData.treasury, domainHash: orgData.domainHash, contentURI: _contentURI(orgId)});
    }

    /// @inheritdoc IOrgRegistry
    function nextOrgId() external view returns (uint256 nextId) {
        return _nextOrgId + 1;
    }

    /// @inheritdoc IOrgRegistry
    function isOperator(address account) external view returns (bool) {
        return _isOperator(account);
    }

    /// @inheritdoc IOrgRegistry
    function operators() external view returns (address[] memory operators_) {
        return _operatorsList();
    }

    /// @inheritdoc IOrgRegistry
    function isExecutor(address account) external view returns (bool) {
        return _isExecutor(account);
    }

    /// @inheritdoc IOrgRegistry
    function executors() external view returns (address[] memory executors_) {
        return _executorsList();
    }

    /// @inheritdoc IOrgRegistry
    function isOrgAdmin(uint256 orgId, address account) external view returns (bool active) {
        if (!_orgExists(orgId)) revert Errors.OrgNotFound(orgId);

        return _isOrgAdmin(orgId, account);
    }

    /// @inheritdoc IOrgRegistry
    function orgAdmins(uint256 orgId) external view returns (address[] memory admins) {
        if (!_orgExists(orgId)) revert Errors.OrgNotFound(orgId);

        return _orgAdminsList(orgId);
    }

    /// @inheritdoc IOrgRegistry
    function orgTreasury(uint256 orgId) external view returns (address treasury_) {
        return _requireOrg(orgId).treasury;
    }

    /// @inheritdoc IOrgRegistry
    function pendingOrgTreasury(uint256 orgId) external view returns (PendingOrgTreasuryView memory pending) {
        if (!_orgExists(orgId)) revert Errors.OrgNotFound(orgId);

        TreasuryTransfer storage transfer = _pendingTreasury[orgId];

        return PendingOrgTreasuryView({proposedTreasury: transfer.proposedTreasury, accepted: transfer.accepted});
    }

    /// @inheritdoc IOrgRegistry
    function orgExists(uint256 orgId) external view returns (bool exists) {
        return _orgExists(orgId);
    }

    /// @notice Returns the EIP-712 domain separator
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _operatorDomainSeparator();
    }
}
