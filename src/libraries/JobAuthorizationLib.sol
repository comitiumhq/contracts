// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title JobAuthorizationLib
/// @notice EIP-712 schemas and nonce scopes owned by JobCommitment.
library JobAuthorizationLib {
    uint16 internal constant NONCE_SCOPE_JOB_PUBLISH = 1;
    uint16 internal constant NONCE_SCOPE_JOB_CLOSE = 2;
    uint16 internal constant NONCE_SCOPE_JOB_UNPUBLISH = 4;
    uint16 internal constant NONCE_SCOPE_JOB_EXPIRED_SETTLEMENT = 7;

    bytes32 internal constant JOB_PUBLISH_TYPEHASH = keccak256(
        "JobPublish(uint256 orgId,uint256 stake,uint8 feeTier,bytes32 postingRef,address creator,uint32 configVersion,uint256 keyNonce,uint256 expiry)"
    );

    bytes32 internal constant APPLICATION_TYPEHASH =
        keccak256("Application(bytes32 applicationId,address applicant,uint8 responseDeadlineDays,uint256 expiry)");

    bytes32 internal constant JOB_CLOSE_TYPEHASH = keccak256(
        "JobClose(uint256 jobId,uint32 totalApplications,uint32 respondedApplications,uint32 onTimeResponses,bytes32 counterSnapshotRoot,address closer,uint256 keyNonce,uint256 expiry)"
    );

    bytes32 internal constant JOB_EXPIRED_SETTLEMENT_TYPEHASH = keccak256(
        "JobExpiredSettlement(uint256 jobId,uint32 totalApplications,uint32 respondedApplications,uint32 onTimeResponses,bytes32 counterSnapshotRoot,uint256 keyNonce,uint256 expiry)"
    );

    bytes32 internal constant JOB_UNPUBLISH_TYPEHASH =
        keccak256("JobUnpublish(uint256 jobId,address unpublisher,uint256 keyNonce,uint256 expiry)");

    function hashJobPublish(
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
                JOB_PUBLISH_TYPEHASH, orgId, stake, feeTier, postingRef, creator, configVersion, keyNonce, expiry
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

    function hashJobClose(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        address closer,
        uint256 keyNonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                JOB_CLOSE_TYPEHASH,
                jobId,
                totalApplications,
                respondedApplications,
                onTimeResponses,
                counterSnapshotRoot,
                closer,
                keyNonce,
                expiry
            )
        );
    }

    function hashJobExpiredSettlement(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                JOB_EXPIRED_SETTLEMENT_TYPEHASH,
                jobId,
                totalApplications,
                respondedApplications,
                onTimeResponses,
                counterSnapshotRoot,
                keyNonce,
                expiry
            )
        );
    }

    function hashJobUnpublish(uint256 jobId, address unpublisher, uint256 keyNonce, uint256 expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(JOB_UNPUBLISH_TYPEHASH, jobId, unpublisher, keyNonce, expiry));
    }
}
