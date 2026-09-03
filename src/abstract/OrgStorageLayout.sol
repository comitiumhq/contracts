// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Errors} from "../Errors.sol";
import {Org, TreasuryTransfer} from "../types/OrgTypes.sol";
import {ContentURIRegistry} from "./ContentURIRegistry.sol";
import {OperatorAuthorizer} from "./OperatorAuthorizer.sol";

/// @title OrgStorageLayout
/// @notice Shared plain storage layout for OrgRegistry modules.
abstract contract OrgStorageLayout is OperatorAuthorizer, ContentURIRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Counter for org IDs (starts at 1).
    uint256 internal _nextOrgId;

    /// @notice Mapping from org ID to organization data.
    mapping(uint256 orgId => Org) internal _organizations;

    /// @notice Per-org product administrators.
    mapping(uint256 orgId => EnumerableSet.AddressSet) internal _orgAdmins;

    /// @notice Pending per-org treasury transfers.
    mapping(uint256 orgId => TreasuryTransfer) internal _pendingTreasury;

    // ============ Internal Helpers ============

    /// @notice Check whether an organization exists.
    /// @param orgId Organization ID.
    /// @return exists True when the org exists.
    function _orgExists(uint256 orgId) internal view returns (bool exists) {
        return _organizations[orgId].treasury != address(0);
    }

    /// @notice Require an organization to exist.
    /// @param orgId Organization ID.
    /// @return orgData Organization storage reference.
    function _requireOrg(uint256 orgId) internal view returns (Org storage orgData) {
        orgData = _organizations[orgId];

        if (orgData.treasury == address(0)) revert Errors.OrgNotFound(orgId);
    }

    /// @notice Check whether an account is an active org admin.
    /// @param orgId Organization ID.
    /// @param account Account to check.
    /// @return active True when account is an active org admin.
    function _isOrgAdmin(uint256 orgId, address account) internal view returns (bool active) {
        return _orgAdmins[orgId].contains(account);
    }

    /// @notice Get all active org admins.
    /// @param orgId Organization ID.
    /// @return admins Active org admin addresses.
    function _orgAdminsList(uint256 orgId) internal view returns (address[] memory admins) {
        return _orgAdmins[orgId].values();
    }

    /// @notice Get active org admin count.
    /// @param orgId Organization ID.
    /// @return count Active org admin count.
    function _orgAdminCount(uint256 orgId) internal view returns (uint256 count) {
        return _orgAdmins[orgId].length();
    }

    /// @notice Caller identity for modules that support a user actor.
    /// @dev Default returns the raw caller for standalone use; the concrete OrgRegistry overrides it with the
    ///      ERC-2771 actor.
    function _actor() internal view virtual returns (address) {
        return msg.sender;
    }

    /// @notice Get content URI for an org
    /// @param orgId Organization ID
    /// @return uri Content URI string
    function _contentURI(uint256 orgId) internal view returns (string storage uri) {
        return _contentURI(_orgURIKey(orgId));
    }

    /// @notice Set content URI for an org
    /// @param orgId Organization ID
    /// @param uri Content URI string
    function _setContentURI(uint256 orgId, string memory uri) internal {
        _setContentURI(_orgURIKey(orgId), uri);
    }

    /// @notice Build the content key for an organization.
    /// @param orgId Organization ID.
    /// @return key Content URI storage key.
    function _orgURIKey(uint256 orgId) internal pure returns (bytes32 key) {
        return keccak256(abi.encode("ORG", orgId));
    }
}
