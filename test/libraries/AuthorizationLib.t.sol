// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {JobAuthorizationLib} from "../../src/libraries/JobAuthorizationLib.sol";
import {OrgAuthorizationLib} from "../../src/libraries/OrgAuthorizationLib.sol";

contract AuthorizationLibTest is Test {
    uint256 private constant OPERATOR_PRIVATE_KEY = 0x1234;
    bytes32 private constant DOMAIN_SEPARATOR = keccak256("test-domain");

    // Reference the library's own typehash constants (not local copies) so the *_matchesManualVector tests
    // exercise the real source values — a re-declared copy would silently hide a source drift.
    bytes32 internal constant JOB_PUBLISH_TYPEHASH = JobAuthorizationLib.JOB_PUBLISH_TYPEHASH;
    bytes32 internal constant APPLICATION_TYPEHASH = JobAuthorizationLib.APPLICATION_TYPEHASH;
    bytes32 internal constant JOB_CLOSE_TYPEHASH = JobAuthorizationLib.JOB_CLOSE_TYPEHASH;
    bytes32 internal constant JOB_EXPIRED_SETTLEMENT_TYPEHASH = JobAuthorizationLib.JOB_EXPIRED_SETTLEMENT_TYPEHASH;
    bytes32 internal constant JOB_UNPUBLISH_TYPEHASH = JobAuthorizationLib.JOB_UNPUBLISH_TYPEHASH;
    bytes32 internal constant JOB_CONTENT_URI_UPDATE_TYPEHASH = JobAuthorizationLib.JOB_CONTENT_URI_UPDATE_TYPEHASH;
    bytes32 internal constant DOMAIN_VERIFICATION_TYPEHASH = OrgAuthorizationLib.DOMAIN_VERIFICATION_TYPEHASH;
    bytes32 internal constant ORG_DOMAIN_UPDATE_TYPEHASH = OrgAuthorizationLib.ORG_DOMAIN_UPDATE_TYPEHASH;

    /// @notice Independent oracle: frozen EIP-712 typehash digests computed out-of-band (`cast keccak` of the
    ///         canonical type string). If a source type string changes field order/name/type, the source
    ///         constant changes and these fail — catching the exact bug the self-consistent vector tests cannot.
    function test_typehashes_matchFrozenEip712Spec() public pure {
        assertEq(
            JobAuthorizationLib.JOB_PUBLISH_TYPEHASH,
            0x40115f000192d1ee5d4239c74b587c4a7bed71026182bddff0cb3f56c7443cff,
            "JobPublish typehash drifted"
        );
        assertEq(
            JobAuthorizationLib.APPLICATION_TYPEHASH,
            0xe2d955395daec500734d9c439eabd7e1e018212fdb7590d8bdb0d852a4a5a9be,
            "Application typehash drifted"
        );
        assertEq(
            JobAuthorizationLib.JOB_CLOSE_TYPEHASH,
            0x8f6fe62b0f35c742b8272c1a2094c94999a3efb16ba9d092f6255197288cba0f,
            "JobClose typehash drifted"
        );
        assertEq(
            JobAuthorizationLib.JOB_EXPIRED_SETTLEMENT_TYPEHASH,
            0x5c39d47b74c2e59692dacd7e1a5941d7d1a343c34763cb9661edeb805b0dfb65,
            "JobExpiredSettlement typehash drifted"
        );
        assertEq(
            JobAuthorizationLib.JOB_UNPUBLISH_TYPEHASH,
            0xcf2a0216dd030f5b6d77690409771dafdd532eb960861c3aa60179142561baa5,
            "JobUnpublish typehash drifted"
        );
        assertEq(
            JobAuthorizationLib.JOB_CONTENT_URI_UPDATE_TYPEHASH,
            0x033c69ef789142bfcf999327410f43bff26016a40219bfe0fbf9690b48e7993d,
            "JobContentURIUpdate typehash drifted"
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
        assertEq(JobAuthorizationLib.NONCE_SCOPE_JOB_PUBLISH, 1, "JobPublish nonce scope drifted");
        assertEq(JobAuthorizationLib.NONCE_SCOPE_JOB_CLOSE, 2, "JobClose nonce scope drifted");
        assertEq(OrgAuthorizationLib.NONCE_SCOPE_DOMAIN_VERIFICATION, 3, "DomainVerification nonce scope drifted");
        assertEq(JobAuthorizationLib.NONCE_SCOPE_JOB_UNPUBLISH, 4, "JobUnpublish nonce scope drifted");
        assertEq(JobAuthorizationLib.NONCE_SCOPE_JOB_CONTENT_URI_UPDATE, 5, "JobContentURIUpdate nonce scope drifted");
        assertEq(OrgAuthorizationLib.NONCE_SCOPE_ORG_DOMAIN_UPDATE, 6, "OrgDomainUpdate nonce scope drifted");
        assertEq(JobAuthorizationLib.NONCE_SCOPE_JOB_EXPIRED_SETTLEMENT, 7, "JobExpiredSettlement nonce scope drifted");
    }

    function test_hashJobPublish_matchesManualVector() public pure {
        string memory contentURI = "ipfs://job";
        bytes32 expected = keccak256(
            abi.encode(
                JOB_PUBLISH_TYPEHASH,
                uint256(42),
                uint256(300_000_000),
                uint8(1),
                keccak256(bytes(contentURI)),
                address(0xBEEF),
                uint32(2),
                uint256(123),
                uint256(456)
            )
        );

        assertEq(
            JobAuthorizationLib.hashJobPublish(42, 300_000_000, 1, contentURI, address(0xBEEF), 2, 123, 456), expected
        );
    }

    function test_hashApplication_matchesManualVector() public pure {
        bytes32 applicationId = keccak256("application");
        bytes32 expected =
            keccak256(abi.encode(APPLICATION_TYPEHASH, applicationId, address(0xCAFE), uint8(7), uint256(456)));

        assertEq(JobAuthorizationLib.hashApplication(applicationId, address(0xCAFE), 7, 456), expected);
    }

    function test_hashJobClose_matchesManualVector() public pure {
        bytes32 counterSnapshotRoot = keccak256("counter-root");
        bytes32 expected = keccak256(
            abi.encode(
                JOB_CLOSE_TYPEHASH,
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
            JobAuthorizationLib.hashJobClose(7, 10, 9, 8, counterSnapshotRoot, address(0xBEEF), 999, 456), expected
        );
    }

    function test_hashJobExpiredSettlement_matchesManualVector() public pure {
        bytes32 counterSnapshotRoot = keccak256("counter-root");
        bytes32 expected = keccak256(
            abi.encode(
                JOB_EXPIRED_SETTLEMENT_TYPEHASH,
                uint256(7),
                uint32(10),
                uint32(9),
                uint32(8),
                counterSnapshotRoot,
                uint256(999),
                uint256(456)
            )
        );

        assertEq(JobAuthorizationLib.hashJobExpiredSettlement(7, 10, 9, 8, counterSnapshotRoot, 999, 456), expected);
    }

    function test_hashJobUnpublish_matchesManualVector() public pure {
        bytes32 expected =
            keccak256(abi.encode(JOB_UNPUBLISH_TYPEHASH, uint256(7), address(0xBEEF), uint256(123), uint256(456)));

        assertEq(JobAuthorizationLib.hashJobUnpublish(7, address(0xBEEF), 123, 456), expected);
    }

    function test_hashJobContentURIUpdate_matchesManualVector() public pure {
        string memory contentURI = "ipfs://job-v2";
        bytes32 expected = keccak256(
            abi.encode(
                JOB_CONTENT_URI_UPDATE_TYPEHASH,
                uint256(7),
                keccak256(bytes(contentURI)),
                address(0xBEEF),
                uint256(123),
                uint256(456)
            )
        );

        assertEq(JobAuthorizationLib.hashJobContentURIUpdate(7, contentURI, address(0xBEEF), 123, 456), expected);
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

    function test_hashJobPublish_recoversSigner() public view {
        bytes32 structHash =
            JobAuthorizationLib.hashJobPublish(42, 300_000_000, 1, "ipfs://job", address(0xBEEF), 2, 123, 456);

        _assertRoundTrip(structHash);
    }

    function test_hashApplication_recoversSigner() public view {
        bytes32 structHash = JobAuthorizationLib.hashApplication(keccak256("application"), address(0xCAFE), 7, 456);

        _assertRoundTrip(structHash);
    }

    function test_hashJobClose_recoversSigner() public view {
        bytes32 structHash =
            JobAuthorizationLib.hashJobClose(7, 10, 9, 8, keccak256("counter-root"), address(0xBEEF), 999, 456);

        _assertRoundTrip(structHash);
    }

    function test_hashJobExpiredSettlement_recoversSigner() public view {
        bytes32 structHash =
            JobAuthorizationLib.hashJobExpiredSettlement(7, 10, 9, 8, keccak256("counter-root"), 999, 456);

        _assertRoundTrip(structHash);
    }

    function test_hashJobUnpublish_recoversSigner() public view {
        bytes32 structHash = JobAuthorizationLib.hashJobUnpublish(7, address(0xBEEF), 123, 456);

        _assertRoundTrip(structHash);
    }

    function test_hashJobContentURIUpdate_recoversSigner() public view {
        bytes32 structHash = JobAuthorizationLib.hashJobContentURIUpdate(7, "ipfs://job-v2", address(0xBEEF), 123, 456);

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
