// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title CommitmentAuthorizationLib
/// @notice EIP-712 schemas and nonce scopes owned by ResponseCommitment.
library CommitmentAuthorizationLib {
    uint16 internal constant NONCE_SCOPE_COMMITMENT_ACTIVATION = 1;
    uint16 internal constant NONCE_SCOPE_COMMITMENT_SETTLEMENT = 2;
    uint16 internal constant NONCE_SCOPE_COMMITMENT_STOP = 4;
    uint16 internal constant NONCE_SCOPE_EXPIRED_COMMITMENT_SETTLEMENT = 7;

    bytes32 internal constant COMMITMENT_ACTIVATION_TYPEHASH = keccak256(
        "CommitmentActivation(uint256 orgId,uint256 stake,uint8 feeTier,bytes32 postingRef,address creator,uint32 configVersion,uint256 keyNonce,uint256 expiry)"
    );

    bytes32 internal constant APPLICATION_TYPEHASH =
        keccak256("Application(bytes32 applicationId,address applicant,uint8 responseDeadlineDays,uint256 expiry)");

    bytes32 internal constant COMMITMENT_SETTLEMENT_TYPEHASH = keccak256(
        "CommitmentSettlement(uint256 commitmentId,uint32 totalApplications,uint32 respondedApplications,uint32 onTimeResponses,bytes32 counterSnapshotRoot,address settler,uint256 keyNonce,uint256 expiry)"
    );

    bytes32 internal constant EXPIRED_COMMITMENT_SETTLEMENT_TYPEHASH = keccak256(
        "ExpiredCommitmentSettlement(uint256 commitmentId,uint32 totalApplications,uint32 respondedApplications,uint32 onTimeResponses,bytes32 counterSnapshotRoot,uint256 keyNonce,uint256 expiry)"
    );

    bytes32 internal constant COMMITMENT_STOP_TYPEHASH =
        keccak256("CommitmentStop(uint256 commitmentId,address stopper,uint256 keyNonce,uint256 expiry)");

    function hashCommitmentActivation(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        bytes32 postingRef,
        address creator,
        uint32 configVersion,
        uint256 keyNonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                COMMITMENT_ACTIVATION_TYPEHASH,
                orgId,
                stake,
                feeTier,
                postingRef,
                creator,
                configVersion,
                keyNonce,
                expiry
            )
        );
    }

    function hashApplication(bytes32 applicationId, address applicant, uint8 responseDeadlineDays, uint256 expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(APPLICATION_TYPEHASH, applicationId, applicant, responseDeadlineDays, expiry));
    }

    function hashCommitmentSettlement(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        address settler,
        uint256 keyNonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                COMMITMENT_SETTLEMENT_TYPEHASH,
                commitmentId,
                totalApplications,
                respondedApplications,
                onTimeResponses,
                counterSnapshotRoot,
                settler,
                keyNonce,
                expiry
            )
        );
    }

    function hashExpiredCommitmentSettlement(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EXPIRED_COMMITMENT_SETTLEMENT_TYPEHASH,
                commitmentId,
                totalApplications,
                respondedApplications,
                onTimeResponses,
                counterSnapshotRoot,
                keyNonce,
                expiry
            )
        );
    }

    function hashCommitmentStop(uint256 commitmentId, address stopper, uint256 keyNonce, uint256 expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(COMMITMENT_STOP_TYPEHASH, commitmentId, stopper, keyNonce, expiry));
    }
}
