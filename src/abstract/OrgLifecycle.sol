// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {OrgStorageLayout} from "./OrgStorageLayout.sol";
import {IOrgRegistry} from "../interfaces/IOrgRegistry.sol";
import {Errors} from "../Errors.sol";
import {OrgAuthorizationLib} from "../libraries/OrgAuthorizationLib.sol";
import {Org, TreasuryTransfer} from "../types/OrgTypes.sol";

/// @title OrgLifecycle
/// @notice Handles organization creation, admin grants, and treasury rotation.
abstract contract OrgLifecycle is OrgStorageLayout {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Create a new organization with domain verification
    /// @param domainHash Verified organization domain hash
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the operator signature expires
    /// @param signature Operator EIP-712 signature
    /// @param requestHash Hash of the sender-stripped createOrg calldata.
    /// @return orgId The ID of the created organization
    function _createOrg(
        bytes32 domainHash,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature,
        bytes32 requestHash
    ) internal returns (uint256 orgId) {
        if (domainHash == bytes32(0)) revert Errors.ZeroDomainHash();

        address actor = _actor();

        _verifyDomainSignature(domainHash, actor, keyNonce, expiry, signature);

        _nextOrgId++;
        orgId = _nextOrgId;

        Org storage orgData = _organizations[orgId];

        orgData.treasury = actor;
        orgData.domainHash = domainHash;

        bool added = _orgAdmins[orgId].add(actor);
        assert(added);

        emit IOrgRegistry.OrgCreated(orgId, actor, orgData.domainHash, requestHash);
        emit IOrgRegistry.OrgAdminUpdated(orgId, actor, true, actor, true);
    }

    /// @notice Update the active org domain hash.
    /// @param orgId Organization ID.
    /// @param currentDomainHash Expected current domain hash.
    /// @param newDomainHash New verified domain hash.
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce.
    /// @param expiry Timestamp after which the operator signature expires.
    /// @param signature Operator EIP-712 signature.
    /// @param requestHash Hash of the sender-stripped updateOrgDomain calldata.
    function _updateOrgDomain(
        uint256 orgId,
        bytes32 currentDomainHash,
        bytes32 newDomainHash,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature,
        bytes32 requestHash
    ) internal {
        if (newDomainHash == bytes32(0)) revert Errors.ZeroDomainHash();
        if (newDomainHash == currentDomainHash) revert Errors.SameOrgDomainHash(orgId, newDomainHash);

        Org storage orgData = _requireOrg(orgId);

        if (orgData.domainHash != currentDomainHash) {
            revert Errors.OrgDomainHashMismatch(orgId, currentDomainHash, orgData.domainHash);
        }

        address actor = _actor();

        _requireOrgAdmin(orgId, actor);

        _verifyOrgDomainUpdateSignature(orgId, currentDomainHash, newDomainHash, actor, keyNonce, expiry, signature);

        orgData.domainHash = newDomainHash;

        emit IOrgRegistry.OrgDomainUpdated(orgId, currentDomainHash, newDomainHash, actor, requestHash);
    }

    /// @notice Enable or disable an org admin.
    /// @param orgId Organization ID.
    /// @param account Account to update.
    /// @param active Whether the account should be an active org admin.
    function _setOrgAdmin(uint256 orgId, address account, bool active) internal {
        if (account == address(0)) revert Errors.ZeroAddress();

        address actor = _actor();

        _requireOrgAdmin(orgId, actor);

        EnumerableSet.AddressSet storage admins = _orgAdmins[orgId];

        if (!active && admins.contains(account) && _orgAdminCount(orgId) == 1) {
            revert Errors.CannotRemoveLastOrgAdmin(orgId);
        }

        if (account == actor) revert Errors.CannotUpdateOwnOrgAdmin(orgId, account);

        bool changed = active ? admins.add(account) : admins.remove(account);

        emit IOrgRegistry.OrgAdminUpdated(orgId, account, active, actor, changed);
    }

    /// @notice Propose a new org treasury.
    /// @param orgId Organization ID.
    /// @param newTreasury Proposed replacement treasury.
    function _proposeOrgTreasuryTransfer(uint256 orgId, address newTreasury) internal {
        if (newTreasury == address(0)) revert Errors.ZeroAddress();
        if (newTreasury == address(this)) revert Errors.InvalidOrgTreasury(newTreasury);

        address actor = _actor();

        Org storage orgData = _requireOrgTreasury(orgId, actor);

        if (newTreasury == orgData.treasury) revert Errors.SameOrgTreasury(orgId, newTreasury);

        TreasuryTransfer storage pending = _pendingTreasury[orgId];

        if (pending.proposedTreasury != address(0)) {
            revert Errors.PendingOrgTreasuryExists(orgId, pending.proposedTreasury);
        }

        pending.proposedTreasury = newTreasury;
        pending.accepted = false;

        emit IOrgRegistry.OrgTreasuryTransferProposed(orgId, orgData.treasury, newTreasury);
    }

    /// @notice Accept a pending treasury transfer as the proposed treasury.
    /// @param orgId Organization ID.
    function _acceptOrgTreasuryTransfer(uint256 orgId) internal {
        _requireOrg(orgId);

        address actor = _actor();
        TreasuryTransfer storage pending = _pendingTreasury[orgId];

        if (pending.proposedTreasury == address(0)) revert Errors.NoPendingOrgTreasury(orgId);
        if (actor != pending.proposedTreasury) revert Errors.NotProposedOrgTreasury(orgId, actor);

        if (!pending.accepted) {
            pending.accepted = true;

            emit IOrgRegistry.OrgTreasuryTransferAccepted(orgId, actor);
        }
    }

    /// @notice Finalize an accepted treasury transfer.
    /// @param orgId Organization ID.
    function _finalizeOrgTreasuryTransfer(uint256 orgId) internal {
        address actor = _actor();

        _requireOrgAdmin(orgId, actor);

        TreasuryTransfer memory pending = _pendingTreasury[orgId];

        if (pending.proposedTreasury == address(0)) revert Errors.NoPendingOrgTreasury(orgId);
        if (!pending.accepted) revert Errors.OrgTreasuryNotAccepted(orgId);

        Org storage orgData = _organizations[orgId];
        address previousTreasury = orgData.treasury;

        orgData.treasury = pending.proposedTreasury;
        delete _pendingTreasury[orgId];

        emit IOrgRegistry.OrgTreasuryTransferFinalized(orgId, previousTreasury, orgData.treasury, actor);
    }

    /// @notice Cancel a pending treasury transfer.
    /// @param orgId Organization ID.
    function _cancelOrgTreasuryTransfer(uint256 orgId) internal {
        Org storage orgData = _requireOrg(orgId);
        address actor = _actor();

        if (actor != orgData.treasury && !_isOrgAdmin(orgId, actor)) {
            revert Errors.NotOrgTreasuryOrAdmin(orgId, actor);
        }

        TreasuryTransfer memory pending = _pendingTreasury[orgId];

        if (pending.proposedTreasury == address(0)) revert Errors.NoPendingOrgTreasury(orgId);

        delete _pendingTreasury[orgId];

        emit IOrgRegistry.OrgTreasuryTransferCanceled(orgId, orgData.treasury, pending.proposedTreasury, actor);
    }

    /// @notice Require an active org admin.
    /// @param orgId Organization ID.
    /// @param account Account to check.
    function _requireOrgAdmin(uint256 orgId, address account) internal view {
        _requireOrg(orgId);

        if (!_isOrgAdmin(orgId, account)) revert Errors.NotOrgAdmin(orgId, account);
    }

    /// @notice Require the current org treasury.
    /// @param orgId Organization ID.
    /// @param account Account to check.
    /// @return orgData Organization storage reference.
    function _requireOrgTreasury(uint256 orgId, address account) internal view returns (Org storage orgData) {
        orgData = _requireOrg(orgId);

        if (account != orgData.treasury) revert Errors.NotOrgTreasury(orgId, account);
    }

    /// @notice Verify domain verification signature using EIP-712
    /// @param domainHash The verified organization domain hash
    /// @param creator The organization creator address
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature
    function _verifyDomainSignature(
        bytes32 domainHash,
        address creator,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) internal {
        bytes32 structHash = OrgAuthorizationLib.hashDomainVerification(domainHash, creator, keyNonce, expiry);
        _consumeOperatorAuthorization(
            structHash, OrgAuthorizationLib.NONCE_SCOPE_DOMAIN_VERIFICATION, keyNonce, expiry, signature
        );
    }

    /// @notice Verify org domain update signature using EIP-712.
    function _verifyOrgDomainUpdateSignature(
        uint256 orgId,
        bytes32 currentDomainHash,
        bytes32 newDomainHash,
        address updater,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) internal {
        bytes32 structHash = OrgAuthorizationLib.hashOrgDomainUpdate(
            orgId, currentDomainHash, newDomainHash, updater, keyNonce, expiry
        );
        _consumeOperatorAuthorization(
            structHash, OrgAuthorizationLib.NONCE_SCOPE_ORG_DOMAIN_UPDATE, keyNonce, expiry, signature
        );
    }
}
