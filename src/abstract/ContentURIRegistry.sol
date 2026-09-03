// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title ContentURIRegistry
/// @notice Shared storage helper for content URI fields.
abstract contract ContentURIRegistry {
    mapping(bytes32 key => string uri) private _contentURIs;

    /// @notice Store a content URI by key.
    /// @param key Caller-derived content key.
    /// @param uri Content URI to store.
    function _setContentURI(bytes32 key, string memory uri) internal {
        _contentURIs[key] = uri;
    }

    /// @notice Read a content URI by key.
    /// @param key Caller-derived content key.
    /// @return uri Stored content URI.
    function _contentURI(bytes32 key) internal view returns (string storage uri) {
        return _contentURIs[key];
    }
}
