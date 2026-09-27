// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {CommitmentAuthorizationLib} from "../../src/libraries/CommitmentAuthorizationLib.sol";
import {OrgAuthorizationLib} from "../../src/libraries/OrgAuthorizationLib.sol";

contract AuthorizationLibTest is Test {
    uint256 private constant OPERATOR_PRIVATE_KEY = 0x1234;
    bytes32 private constant DOMAIN_SEPARATOR = keccak256("test-domain");

    // Reference the library's own typehash constants (not local copies) so the *_matchesManualVector tests
    // exercise the real source values — a re-declared copy would silently hide a source drift.
    bytes32 internal constant COMMITMENT_ACTIVATION_TYPEHASH =
        CommitmentAuthorizationLib.COMMITMENT_ACTIVATION_TYPEHASH;
    bytes32 internal constant APPLICATION_TYPEHASH = CommitmentAuthorizationLib.APPLICATION_TYPEHASH;
    bytes32 internal constant COMMITMENT_SETTLEMENT_TYPEHASH =
        CommitmentAuthorizationLib.COMMITMENT_SETTLEMENT_TYPEHASH;
    bytes32 internal constant EXPIRED_COMMITMENT_SETTLEMENT_TYPEHASH =
        CommitmentAuthorizationLib.EXPIRED_COMMITMENT_SETTLEMENT_TYPEHASH;
    bytes32 internal constant COMMITMENT_STOP_TYPEHASH = CommitmentAuthorizationLib.COMMITMENT_STOP_TYPEHASH;
    bytes32 internal constant DOMAIN_VERIFICATION_TYPEHASH = OrgAuthorizationLib.DOMAIN_VERIFICATION_TYPEHASH;
    bytes32 internal constant ORG_DOMAIN_UPDATE_TYPEHASH = OrgAuthorizationLib.ORG_DOMAIN_UPDATE_TYPEHASH;

    /// @notice Independent oracle: frozen EIP-712 typehash digests computed out-of-band (`cast keccak` of the
    ///         canonical type string). If a source type string changes field order/name/type, the source
    ///         constant changes and these fail — catching the exact bug the self-consistent vector tests cannot.
    function test_typehashes_matchFrozenEip712Spec() public pure {
        assertEq(
            CommitmentAuthorizationLib.COMMITMENT_ACTIVATION_TYPEHASH,
            0x4fedbf3814794c013db1a0efc0524d373cc966420259442455509a60d99c190c,
            "CommitmentActivation typehash drifted"
        );
        assertEq(
            CommitmentAuthorizationLib.APPLICATION_TYPEHASH,
            0xe2d955395daec500734d9c439eabd7e1e018212fdb7590d8bdb0d852a4a5a9be,
            "Application typehash drifted"
        );
        assertEq(
            CommitmentAuthorizationLib.COMMITMENT_SETTLEMENT_TYPEHASH,
            0x9b475acf93f4aeae20c5fab82c320c75709a3e3d8a1dd46e77acb1cc7266d684,
            "CommitmentSettlement typehash drifted"
        );
        assertEq(
            CommitmentAuthorizationLib.EXPIRED_COMMITMENT_SETTLEMENT_TYPEHASH,
            0x9e57d76e8ea4f87ac9e4c572a4fb7133944c464f851b1340b357da70454ae751,
            "ExpiredCommitmentSettlement typehash drifted"
        );
        assertEq(
            CommitmentAuthorizationLib.COMMITMENT_STOP_TYPEHASH,
            0x8cebc15e0b1f0bd3ec66da56cc19765a3b2a746fde535d00b55550a8c9124121,
            "CommitmentStop typehash drifted"
        );
        assertEq(
            OrgAuthorizationLib.DOMAIN_VERIFICATION_TYPEHASH,
            0x61b8ad5f716b24d7c5cbffcc48d9dbdda35348a2f99d2ef71e8b40d72ea125b7,
            "DomainVerification typehash drifted"
        );
        assertEq(
            OrgAuthorizationLib.ORG_DOMAIN_UPDATE_TYPEHASH,
            0x15ba4893100609f908434af8d2633333a29edb56b35a9c5642115cb1293f9e2b,
            "OrgDomainUpdate typehash drifted"
        );
    }

    /// @notice Independent compatibility guard for the scoped nonce registry shared with offchain signers.
    function test_nonceScopes_matchFrozenProtocolRegistry() public pure {
        assertEq(
            CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_ACTIVATION, 1, "CommitmentActivation nonce scope drifted"
        );
        assertEq(
            CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_SETTLEMENT, 2, "CommitmentSettlement nonce scope drifted"
        );
        assertEq(OrgAuthorizationLib.NONCE_SCOPE_DOMAIN_VERIFICATION, 3, "DomainVerification nonce scope drifted");
        assertEq(CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_STOP, 4, "CommitmentStop nonce scope drifted");
        assertEq(OrgAuthorizationLib.NONCE_SCOPE_ORG_DOMAIN_UPDATE, 6, "OrgDomainUpdate nonce scope drifted");
        assertEq(
            CommitmentAuthorizationLib.NONCE_SCOPE_EXPIRED_COMMITMENT_SETTLEMENT,
            7,
            "ExpiredCommitmentSettlement nonce scope drifted"
        );
    }

    function test_hashCommitmentActivation_matchesManualVector() public pure {
        bytes32 postingRef = keccak256("posting");
        bytes32 expected = keccak256(
            abi.encode(
                COMMITMENT_ACTIVATION_TYPEHASH,
                uint256(42),
                uint256(300_000_000),
                uint8(1),
                postingRef,
                address(0xBEEF),
                uint32(2),
                uint256(123),
                uint256(456)
            )
        );

        assertEq(
            CommitmentAuthorizationLib.hashCommitmentActivation(
                42, 300_000_000, 1, postingRef, address(0xBEEF), 2, 123, 456
            ),
            expected
        );
    }

    function test_hashApplication_matchesManualVector() public pure {
        bytes32 applicationId = keccak256("application");
        bytes32 expected =
            keccak256(abi.encode(APPLICATION_TYPEHASH, applicationId, address(0xCAFE), uint8(7), uint256(456)));

        assertEq(CommitmentAuthorizationLib.hashApplication(applicationId, address(0xCAFE), 7, 456), expected);
    }

    function test_hashCommitmentSettlement_matchesManualVector() public pure {
        bytes32 counterSnapshotRoot = keccak256("counter-root");
        bytes32 expected = keccak256(
            abi.encode(
                COMMITMENT_SETTLEMENT_TYPEHASH,
                uint256(7),
                uint32(10),
                uint32(9),
                uint32(8),
                counterSnapshotRoot,
                address(0xBEEF),
                uint256(999),
                uint256(456)
            )
        );

        assertEq(
            CommitmentAuthorizationLib.hashCommitmentSettlement(
                7, 10, 9, 8, counterSnapshotRoot, address(0xBEEF), 999, 456
            ),
            expected
        );
    }

    function test_hashExpiredCommitmentSettlement_matchesManualVector() public pure {
        bytes32 counterSnapshotRoot = keccak256("counter-root");
        bytes32 expected = keccak256(
            abi.encode(
                EXPIRED_COMMITMENT_SETTLEMENT_TYPEHASH,
                uint256(7),
                uint32(10),
                uint32(9),
                uint32(8),
                counterSnapshotRoot,
                uint256(999),
                uint256(456)
            )
        );

        assertEq(
            CommitmentAuthorizationLib.hashExpiredCommitmentSettlement(7, 10, 9, 8, counterSnapshotRoot, 999, 456),
            expected
        );
    }

    function test_hashCommitmentStop_matchesManualVector() public pure {
        bytes32 expected =
            keccak256(abi.encode(COMMITMENT_STOP_TYPEHASH, uint256(7), address(0xBEEF), uint256(123), uint256(456)));

        assertEq(CommitmentAuthorizationLib.hashCommitmentStop(7, address(0xBEEF), 123, 456), expected);
    }

    function test_hashDomainVerification_matchesManualVector() public pure {
        bytes32 domainHash = keccak256("example.com");
        bytes32 expected = keccak256(
            abi.encode(DOMAIN_VERIFICATION_TYPEHASH, domainHash, address(0xBEEF), uint256(123), uint256(456))
        );

        assertEq(OrgAuthorizationLib.hashDomainVerification(domainHash, address(0xBEEF), 123, 456), expected);
    }

    function test_hashOrgDomainUpdate_matchesManualVector() public pure {
        bytes32 currentDomainHash = keccak256("example.com");
        bytes32 newDomainHash = keccak256("new-example.com");
        bytes32 expected = keccak256(
            abi.encode(
                ORG_DOMAIN_UPDATE_TYPEHASH,
                uint256(42),
                currentDomainHash,
                newDomainHash,
                address(0xBEEF),
                uint256(123),
                uint256(456)
            )
        );

        assertEq(
            OrgAuthorizationLib.hashOrgDomainUpdate(42, currentDomainHash, newDomainHash, address(0xBEEF), 123, 456),
            expected
        );
    }

    function test_hashCommitmentActivation_recoversSigner() public view {
        bytes32 structHash = CommitmentAuthorizationLib.hashCommitmentActivation(
            42, 300_000_000, 1, keccak256("posting"), address(0xBEEF), 2, 123, 456
        );

        _assertRoundTrip(structHash);
    }

    function test_hashApplication_recoversSigner() public view {
        bytes32 structHash =
            CommitmentAuthorizationLib.hashApplication(keccak256("application"), address(0xCAFE), 7, 456);

        _assertRoundTrip(structHash);
    }

    function test_hashCommitmentSettlement_recoversSigner() public view {
        bytes32 structHash = CommitmentAuthorizationLib.hashCommitmentSettlement(
            7, 10, 9, 8, keccak256("counter-root"), address(0xBEEF), 999, 456
        );

        _assertRoundTrip(structHash);
    }

    function test_hashExpiredCommitmentSettlement_recoversSigner() public view {
        bytes32 structHash = CommitmentAuthorizationLib.hashExpiredCommitmentSettlement(
            7, 10, 9, 8, keccak256("counter-root"), 999, 456
        );

        _assertRoundTrip(structHash);
    }

    function test_hashCommitmentStop_recoversSigner() public view {
        bytes32 structHash = CommitmentAuthorizationLib.hashCommitmentStop(7, address(0xBEEF), 123, 456);

        _assertRoundTrip(structHash);
    }

    function test_hashDomainVerification_recoversSigner() public view {
        bytes32 structHash =
            OrgAuthorizationLib.hashDomainVerification(keccak256("example.com"), address(0xBEEF), 123, 456);

        _assertRoundTrip(structHash);
    }

    function test_hashOrgDomainUpdate_recoversSigner() public view {
        bytes32 structHash = OrgAuthorizationLib.hashOrgDomainUpdate(
            42, keccak256("example.com"), keccak256("new-example.com"), address(0xBEEF), 123, 456
        );

        _assertRoundTrip(structHash);
    }

    function _assertRoundTrip(bytes32 structHash) private view {
        bytes32 digest = MessageHashUtils.toTypedDataHash(DOMAIN_SEPARATOR, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OPERATOR_PRIVATE_KEY, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertEq(ECDSA.recover(digest, signature), vm.addr(OPERATOR_PRIVATE_KEY));
    }
}
