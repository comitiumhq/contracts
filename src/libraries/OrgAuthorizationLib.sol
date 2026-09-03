// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title OrgAuthorizationLib
/// @notice EIP-712 schemas and nonce scopes owned by OrgRegistry.
library OrgAuthorizationLib {
    uint16 internal constant NONCE_SCOPE_DOMAIN_VERIFICATION = 3;
    uint16 internal constant NONCE_SCOPE_ORG_DOMAIN_UPDATE = 6;

    bytes32 internal constant DOMAIN_VERIFICATION_TYPEHASH =
        keccak256("DomainVerification(bytes32 domainHash,address creator,uint256 keyNonce,uint256 expiry)");

    bytes32 internal constant ORG_DOMAIN_UPDATE_TYPEHASH = keccak256(
        "OrgDomainUpdate(uint256 orgId,bytes32 currentDomainHash,bytes32 newDomainHash,address updater,uint256 keyNonce,uint256 expiry)"
    );

    function hashDomainVerification(bytes32 domainHash, address creator, uint256 keyNonce, uint256 expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(DOMAIN_VERIFICATION_TYPEHASH, domainHash, creator, keyNonce, expiry));
    }

    function hashOrgDomainUpdate(
        uint256 orgId,
        bytes32 currentDomainHash,
        bytes32 newDomainHash,
        address updater,
        uint256 keyNonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(ORG_DOMAIN_UPDATE_TYPEHASH, orgId, currentDomainHash, newDomainHash, updater, keyNonce, expiry)
        );
    }
}
