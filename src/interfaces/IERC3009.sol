// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IERC3009
/// @notice Minimal interface for receiving tokens through an EIP-3009 authorization.
interface IERC3009 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
