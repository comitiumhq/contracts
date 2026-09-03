// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Organization data stored by OrgRegistry.
struct Org {
    /// @notice Financial wallet controlling fund deposits and withdrawals.
    address treasury;
    /// @notice Hash of the verified organization domain.
    bytes32 domainHash;
}

/// @notice Pending org treasury transfer state.
struct TreasuryTransfer {
    /// @notice Proposed replacement treasury wallet.
    address proposedTreasury;
    /// @notice Whether the proposed treasury accepted the transfer.
    bool accepted;
}
