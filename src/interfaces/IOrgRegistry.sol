// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

// ============ Structs ============

/// @notice Organization data returned by view functions
struct OrgView {
    address treasury;
    bytes32 domainHash;
    string contentURI;
}

/// @notice Pending org treasury transfer returned by view functions.
struct PendingOrgTreasuryView {
    address proposedTreasury;
    bool accepted;
}

// ============ Interface ============

/// @title IOrgRegistry
/// @notice Integration interface for the OrgRegistry contract (excludes owner/governance functions).
interface IOrgRegistry {
    // ---- Events: Lifecycle ----

    /// @notice Emitted when a new organization is created.
    event OrgCreated(uint256 indexed orgId, address indexed creator, bytes32 indexed domainHash, bytes32 requestHash);

    /// @notice Emitted when the active org domain hash is updated.
    event OrgDomainUpdated(
        uint256 indexed orgId,
        bytes32 previousDomainHash,
        bytes32 indexed newDomainHash,
        address indexed updater,
        bytes32 requestHash
    );

    /// @notice Emitted when an org admin is enabled or disabled.
    event OrgAdminUpdated(
        uint256 indexed orgId, address indexed account, bool active, address indexed actor, bool changed
    );

    /// @notice Emitted when current treasury proposes a replacement treasury.
    event OrgTreasuryTransferProposed(
        uint256 indexed orgId, address indexed previousTreasury, address indexed proposedTreasury
    );

    /// @notice Emitted when proposed treasury accepts a transfer.
    event OrgTreasuryTransferAccepted(uint256 indexed orgId, address indexed proposedTreasury);

    /// @notice Emitted when an accepted treasury transfer is finalized.
    event OrgTreasuryTransferFinalized(
        uint256 indexed orgId, address indexed previousTreasury, address indexed newTreasury, address finalizer
    );

    /// @notice Emitted when a pending treasury transfer is canceled.
    event OrgTreasuryTransferCanceled(
        uint256 indexed orgId, address indexed previousTreasury, address indexed proposedTreasury, address canceledBy
    );

    // ---- Events: Rescue ----

    /// @notice Emitted when tokens are rescued from the contract
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when organization content URI is updated
    event ContentURIUpdated(uint256 indexed orgId, address indexed updater, string contentURI);

    // ---- Lifecycle ----

    /// @notice Create a new organization with verified domain
    /// @param domainHash Verified domain hash
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce
    /// @param expiry Timestamp after which the signature expires
    /// @param signature Operator signature approving creation
    /// @return orgId The ID of the created organization
    function createOrg(bytes32 domainHash, uint256 keyNonce, uint256 expiry, bytes calldata signature)
        external
        returns (uint256 orgId);

    /// @notice Update the active verified domain hash for an existing organization.
    /// @param orgId Organization ID.
    /// @param currentDomainHash Expected current domain hash.
    /// @param newDomainHash New verified domain hash.
    /// @param keyNonce Packed NoncesKeyed authorization key and nonce.
    /// @param expiry Timestamp after which the signature expires.
    /// @param signature Operator signature approving the update.
    function updateOrgDomain(
        uint256 orgId,
        bytes32 currentDomainHash,
        bytes32 newDomainHash,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata signature
    ) external;

    /// @notice Get organization details
    /// @param orgId Organization ID to query
    /// @return org Organization data
    function org(uint256 orgId) external view returns (OrgView memory org);

    /// @notice Get the next org ID that will be assigned
    /// @return nextId The next organization ID
    function nextOrgId() external view returns (uint256 nextId);

    // ---- State ----

    /// @notice Check if an address is an EIP-712 signing operator.
    function isOperator(address account) external view returns (bool);

    /// @notice List active EIP-712 signing operators.
    function operators() external view returns (address[] memory operators_);

    /// @notice Update organization content URI
    /// @param orgId Organization ID
    /// @param contentURI New IPFS content URI
    function updateContentURI(uint256 orgId, string calldata contentURI) external;

    /// @notice Enable or disable an org admin.
    /// @param orgId Organization ID.
    /// @param account Account to update.
    /// @param active Whether the account should be active.
    function setOrgAdmin(uint256 orgId, address account, bool active) external;

    /// @notice Propose a replacement org treasury.
    /// @param orgId Organization ID.
    /// @param newTreasury Proposed replacement treasury address.
    function proposeOrgTreasuryTransfer(uint256 orgId, address newTreasury) external;

    /// @notice Accept a pending treasury transfer as the proposed treasury.
    /// @param orgId Organization ID.
    function acceptOrgTreasuryTransfer(uint256 orgId) external;

    /// @notice Finalize an accepted treasury transfer.
    /// @param orgId Organization ID.
    function finalizeOrgTreasuryTransfer(uint256 orgId) external;

    /// @notice Cancel a pending treasury transfer.
    /// @param orgId Organization ID.
    function cancelOrgTreasuryTransfer(uint256 orgId) external;

    /// @notice Check whether an account is an active org admin.
    /// @param orgId Organization ID.
    /// @param account Account to check.
    /// @return active True when account is an active org admin.
    function isOrgAdmin(uint256 orgId, address account) external view returns (bool active);

    /// @notice List active org admins.
    /// @param orgId Organization ID.
    /// @return admins Active org admin addresses.
    function orgAdmins(uint256 orgId) external view returns (address[] memory admins);

    /// @notice Get current organization treasury
    /// @param orgId Organization ID
    /// @return treasury Current treasury address
    function orgTreasury(uint256 orgId) external view returns (address treasury);

    /// @notice Get pending org treasury transfer state.
    /// @param orgId Organization ID.
    /// @return pending Pending treasury transfer state.
    function pendingOrgTreasury(uint256 orgId) external view returns (PendingOrgTreasuryView memory pending);

    /// @notice Check whether an organization exists
    /// @param orgId Organization ID
    /// @return exists True when the org exists
    function orgExists(uint256 orgId) external view returns (bool exists);

    /// @notice Returns the EIP-712 domain separator.
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
