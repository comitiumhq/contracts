// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {OrgRegistry} from "../src/OrgRegistry.sol";
import {ResponseCommitment} from "../src/ResponseCommitment.sol";
import {CommitmentFunds} from "../src/CommitmentFunds.sol";
import {IERC3009} from "../src/interfaces/IERC3009.sol";
import {RegisteredResponseCommitment} from "../src/interfaces/ICommitmentFunds.sol";
import {FeeTier, CommitmentConfig} from "../src/types/ConfigTypes.sol";
import {
    BaseScript,
    DeploymentConfigHashes,
    DeploymentOrgRegistry,
    DeploymentCommitmentFunds,
    DeploymentResponseCommitment,
    UnsupportedDeploymentCatalogSchema
} from "./Base.s.sol";

error DeploymentCatalogMissing(string path);
error DeploymentContractCodeMissing(string name, address addr);
error DeploymentRoleMissing(string role, address account);
error DeploymentRolesOverlap(address account);
error DeploymentStakeTokenAuthorizationDomainMismatch(address token, bytes32 expected, bytes32 actual);
error DeploymentCatalogMissingCurrentCommitment(address current);
error DeploymentCatalogDuplicateCommitment(address commitment);

struct ParsedDeploymentCatalog {
    uint256 deploymentSetVersion;
    string network;
    address deployer;
    address stakeToken;
    uint256 startBlock;
    uint256 deployedAtBlock;
    uint256 deployedAtTimestamp;
    string gitCommit;
    address forwarder;
    DeploymentOrgRegistry orgRegistry;
    DeploymentCommitmentFunds commitmentFunds;
    DeploymentResponseCommitment[] responseCommitments;
}

/// @title Validate Comitium deployment wiring
/// @notice Validates the catalog and immutable dependency/version facts against live state.
contract ValidateDeployment is BaseScript, Test {
    uint256 private constant BASE_MAINNET_CHAIN_ID = 8453;

    function run() external view {
        ParsedDeploymentCatalog memory catalog = _parseDeploymentCatalog(_readDeploymentCatalog());

        _assertDeploymentMetadata(catalog);
        _assertSingletons(catalog);
        _assertCommitments(catalog);

        if (vm.envOr("VALIDATE_INITIAL_SNAPSHOTS", true)) _assertInitialSnapshots(catalog);

        _assertConfiguredRoles(catalog);

        console.log("Deployment verification passed");
        console.log("Catalog path: %s", _deploymentFile());
    }

    function _readDeploymentCatalog() private view returns (string memory) {
        string memory file = _deploymentFile();

        if (!vm.exists(file)) revert DeploymentCatalogMissing(file);

        string memory json = vm.readFile(file);
        if (!vm.keyExistsJson(json, _deploymentPath())) revert DeploymentCatalogMissing(file);

        return json;
    }

    function _parseDeploymentCatalog(string memory json) private view returns (ParsedDeploymentCatalog memory catalog) {
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        if (schemaVersion != DEPLOYMENT_CATALOG_SCHEMA_VERSION) {
            revert UnsupportedDeploymentCatalogSchema(schemaVersion);
        }

        string memory path = _deploymentPath();

        catalog.deploymentSetVersion = vm.parseJsonUint(json, string.concat(path, ".deploymentSetVersion"));
        catalog.network = vm.parseJsonString(json, string.concat(path, ".network"));
        catalog.deployer = vm.parseJsonAddress(json, string.concat(path, ".deployer"));
        catalog.stakeToken = vm.parseJsonAddress(json, string.concat(path, ".stakeToken"));
        catalog.startBlock = vm.parseJsonUint(json, string.concat(path, ".startBlock"));
        catalog.deployedAtBlock = vm.parseJsonUint(json, string.concat(path, ".deployedAtBlock"));
        catalog.deployedAtTimestamp = vm.parseJsonUint(json, string.concat(path, ".deployedAtTimestamp"));
        catalog.gitCommit = vm.parseJsonString(json, string.concat(path, ".gitCommit"));
        catalog.forwarder = vm.parseJsonAddress(json, string.concat(path, ".contracts.forwarder"));

        catalog.orgRegistry.address_ = vm.parseJsonAddress(json, string.concat(path, ".contracts.orgRegistry.address"));
        catalog.orgRegistry.domainSeparator =
            vm.parseJsonBytes32(json, string.concat(path, ".contracts.orgRegistry.domainSeparator"));
        catalog.orgRegistry.initialOwner =
            vm.parseJsonAddress(json, string.concat(path, ".contracts.orgRegistry.initialOwner"));
        catalog.orgRegistry.initialOperators =
            vm.parseJsonAddressArray(json, string.concat(path, ".contracts.orgRegistry.initialOperators"));
        catalog.orgRegistry.initialExecutors =
            vm.parseJsonAddressArray(json, string.concat(path, ".contracts.orgRegistry.initialExecutors"));

        catalog.commitmentFunds.address_ =
            vm.parseJsonAddress(json, string.concat(path, ".contracts.commitmentFunds.address"));
        catalog.commitmentFunds.initialOwner =
            vm.parseJsonAddress(json, string.concat(path, ".contracts.commitmentFunds.initialOwner"));
        catalog.commitmentFunds.initialFeeRecipient =
            vm.parseJsonAddress(json, string.concat(path, ".contracts.commitmentFunds.initialFeeRecipient"));
        catalog.responseCommitments = _parseResponseCommitments(json, path);
    }

    function _parseResponseCommitments(string memory json, string memory deploymentPath)
        private
        pure
        returns (DeploymentResponseCommitment[] memory commitments)
    {
        uint256 count;
        for (uint256 i = 0; i < 256; i++) {
            string memory addressPath = string.concat(_commitmentPath(deploymentPath, i), ".address");
            try vm.parseJsonAddress(json, addressPath) returns (address) {
                count++;
            } catch {
                break;
            }
        }

        commitments = new DeploymentResponseCommitment[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory path = _commitmentPath(deploymentPath, i);
            commitments[i] = DeploymentResponseCommitment({
                commitmentVersion: uint32(vm.parseJsonUint(json, string.concat(path, ".commitmentVersion"))),
                address_: vm.parseJsonAddress(json, string.concat(path, ".address")),
                startBlock: vm.parseJsonUint(json, string.concat(path, ".startBlock")),
                domainSeparator: vm.parseJsonBytes32(json, string.concat(path, ".domainSeparator")),
                runtimeCodeHash: vm.parseJsonBytes32(json, string.concat(path, ".runtimeCodeHash")),
                initialOwner: vm.parseJsonAddress(json, string.concat(path, ".initialOwner")),
                initialOperators: vm.parseJsonAddressArray(json, string.concat(path, ".initialOperators")),
                initialExecutors: vm.parseJsonAddressArray(json, string.concat(path, ".initialExecutors")),
                initialConfigHashes: DeploymentConfigHashes({
                    commitmentConfig: vm.parseJsonBytes32(
                        json, string.concat(path, ".initialConfigHashes.commitmentConfig")
                    ),
                    feeTiers: vm.parseJsonBytes32(json, string.concat(path, ".initialConfigHashes.feeTiers"))
                })
            });
        }
    }

    function _commitmentPath(string memory deploymentPath, uint256 index) private pure returns (string memory) {
        return string.concat(deploymentPath, ".contracts.responseCommitments[", vm.toString(index), "]");
    }

    function _assertDeploymentMetadata(ParsedDeploymentCatalog memory catalog) private view {
        assertGt(catalog.deploymentSetVersion, 0, "catalog: deploymentSetVersion is zero");
        assertGt(bytes(catalog.network).length, 0, "catalog: network is empty");
        assertTrue(catalog.deployer != address(0), "catalog: deployer is zero");
        assertGt(catalog.startBlock, 0, "catalog: startBlock is zero");
        assertGe(catalog.deployedAtBlock, catalog.startBlock, "catalog: deployedAtBlock before startBlock");
        assertGt(catalog.deployedAtTimestamp, 0, "catalog: deployedAtTimestamp is zero");
        assertGt(catalog.responseCommitments.length, 0, "catalog: responseCommitments are empty");

        if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            assertGt(bytes(catalog.gitCommit).length, 0, "catalog: mainnet gitCommit is empty");
        }
    }

    function _assertSingletons(ParsedDeploymentCatalog memory catalog) private view {
        _assertHasCode("stakeToken", catalog.stakeToken);
        _assertHasCode("ERC2771Forwarder", catalog.forwarder);
        _assertHasCode("OrgRegistry", catalog.orgRegistry.address_);
        _assertHasCode("CommitmentFunds", catalog.commitmentFunds.address_);

        bytes32 expectedDomainSeparator = _expectedUsdcDomainSeparator(catalog.stakeToken);
        bytes32 actualDomainSeparator = IERC3009(catalog.stakeToken).DOMAIN_SEPARATOR();
        if (actualDomainSeparator != expectedDomainSeparator) {
            revert DeploymentStakeTokenAuthorizationDomainMismatch(
                catalog.stakeToken, expectedDomainSeparator, actualDomainSeparator
            );
        }

        OrgRegistry orgRegistry = OrgRegistry(catalog.orgRegistry.address_);
        CommitmentFunds commitmentFunds = CommitmentFunds(catalog.commitmentFunds.address_);
        assertEq(orgRegistry.trustedForwarder(), catalog.forwarder, "OrgRegistry: forwarder mismatch");
        assertEq(
            orgRegistry.DOMAIN_SEPARATOR(),
            catalog.orgRegistry.domainSeparator,
            "OrgRegistry: domain separator mismatch"
        );
        assertEq(address(commitmentFunds.stakeToken()), catalog.stakeToken, "CommitmentFunds: stakeToken mismatch");
        assertEq(
            address(commitmentFunds.orgRegistry()),
            catalog.orgRegistry.address_,
            "CommitmentFunds: orgRegistry mismatch"
        );
        assertEq(commitmentFunds.trustedForwarder(), catalog.forwarder, "CommitmentFunds: forwarder mismatch");
    }

    function _assertCommitments(ParsedDeploymentCatalog memory catalog) private view {
        CommitmentFunds commitmentFunds = CommitmentFunds(catalog.commitmentFunds.address_);
        address current = commitmentFunds.currentResponseCommitment();
        bool currentFound;

        for (uint256 i = 0; i < catalog.responseCommitments.length; i++) {
            DeploymentResponseCommitment memory entry = catalog.responseCommitments[i];
            assertGt(entry.commitmentVersion, 0, "catalog: commitmentVersion is zero");
            assertGt(entry.startBlock, 0, "catalog: ResponseCommitment startBlock is zero");
            _assertHasCode("ResponseCommitment", entry.address_);
            assertEq(entry.address_.codehash, entry.runtimeCodeHash, "ResponseCommitment: runtime code hash mismatch");

            for (uint256 j = 0; j < i; j++) {
                if (catalog.responseCommitments[j].address_ == entry.address_) {
                    revert DeploymentCatalogDuplicateCommitment(entry.address_);
                }
            }

            ResponseCommitment commitment = ResponseCommitment(entry.address_);
            RegisteredResponseCommitment memory registration =
                commitmentFunds.registeredResponseCommitment(entry.address_);
            assertTrue(registration.exists, "CommitmentFunds: ResponseCommitment not registered");
            assertEq(
                registration.commitmentVersion,
                entry.commitmentVersion,
                "CommitmentFunds: registered commitment version mismatch"
            );
            assertEq(commitment.commitmentVersion(), entry.commitmentVersion, "ResponseCommitment: version mismatch");
            assertEq(
                address(commitment.commitmentFunds()),
                catalog.commitmentFunds.address_,
                "ResponseCommitment: commitmentFunds mismatch"
            );
            assertEq(commitment.trustedForwarder(), catalog.forwarder, "ResponseCommitment: forwarder mismatch");
            assertEq(commitment.DOMAIN_SEPARATOR(), entry.domainSeparator, "ResponseCommitment: domain mismatch");

            if (entry.address_ == current) currentFound = true;
        }

        if (!currentFound) revert DeploymentCatalogMissingCurrentCommitment(current);
    }

    function _assertInitialSnapshots(ParsedDeploymentCatalog memory catalog) private view {
        OrgRegistry orgRegistry = OrgRegistry(catalog.orgRegistry.address_);
        CommitmentFunds commitmentFunds = CommitmentFunds(catalog.commitmentFunds.address_);

        _assertAcceptedOwnership("OrgRegistry", catalog.orgRegistry.address_, catalog.orgRegistry.initialOwner);
        _assertAcceptedOwnership(
            "CommitmentFunds", catalog.commitmentFunds.address_, catalog.commitmentFunds.initialOwner
        );
        _assertSameAddressSet(
            "OrgRegistry initial operators", orgRegistry.operators(), catalog.orgRegistry.initialOperators
        );
        _assertDisjointRoles(catalog.orgRegistry.initialOperators, catalog.orgRegistry.initialExecutors);
        _assertSameAddressSet(
            "OrgRegistry initial executors", orgRegistry.executors(), catalog.orgRegistry.initialExecutors
        );
        assertEq(
            commitmentFunds.feeRecipient(),
            catalog.commitmentFunds.initialFeeRecipient,
            "CommitmentFunds: initial fee recipient mismatch"
        );

        for (uint256 i = 0; i < catalog.responseCommitments.length; i++) {
            DeploymentResponseCommitment memory entry = catalog.responseCommitments[i];
            ResponseCommitment commitment = ResponseCommitment(entry.address_);
            CommitmentConfig memory config = commitment.commitmentConfig(1);
            FeeTier[] memory tiers = commitment.feeTiers(1);

            _assertAcceptedOwnership("ResponseCommitment", entry.address_, entry.initialOwner);
            _assertDisjointRoles(entry.initialOperators, entry.initialExecutors);
            _assertSameAddressSet(
                "ResponseCommitment initial operators", commitment.operators(), entry.initialOperators
            );
            _assertSameAddressSet(
                "ResponseCommitment initial executors", commitment.executors(), entry.initialExecutors
            );
            assertEq(
                keccak256(abi.encode(config)),
                entry.initialConfigHashes.commitmentConfig,
                "ResponseCommitment: initial commitment config hash mismatch"
            );
            assertEq(
                keccak256(abi.encode(tiers)),
                entry.initialConfigHashes.feeTiers,
                "ResponseCommitment: initial fee tiers hash mismatch"
            );
        }
    }

    function _assertConfiguredRoles(ParsedDeploymentCatalog memory catalog) internal view {
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address executor = vm.envAddress("RELAYER_ADDRESS");

        _assertContainsAddress("operator", OrgRegistry(catalog.orgRegistry.address_).operators(), operator);
        _assertContainsAddress("OrgRegistry executor", OrgRegistry(catalog.orgRegistry.address_).executors(), executor);

        for (uint256 i = 0; i < catalog.responseCommitments.length; i++) {
            ResponseCommitment commitment = ResponseCommitment(catalog.responseCommitments[i].address_);
            _assertContainsAddress("ResponseCommitment operator", commitment.operators(), operator);
            _assertContainsAddress("ResponseCommitment executor", commitment.executors(), executor);
        }
    }

    function _assertContainsAddress(string memory role, address[] memory addresses, address expected) private pure {
        for (uint256 i = 0; i < addresses.length; i++) {
            if (addresses[i] == expected) return;
        }

        revert DeploymentRoleMissing(role, expected);
    }

    function _assertDisjointRoles(address[] memory operators, address[] memory executors) private pure {
        for (uint256 i = 0; i < operators.length; i++) {
            for (uint256 j = 0; j < executors.length; j++) {
                if (operators[i] == executors[j]) revert DeploymentRolesOverlap(operators[i]);
            }
        }
    }

    function _assertAcceptedOwnership(string memory name, address contractAddress, address expectedOwner) private view {
        assertEq(_owner(contractAddress), expectedOwner, string.concat(name, ": owner mismatch"));
        assertEq(_pendingOwner(contractAddress), address(0), string.concat(name, ": pending owner must be zero"));
    }

    function _assertSameAddressSet(string memory name, address[] memory actual, address[] memory expected)
        private
        pure
    {
        assertEq(actual.length, expected.length, string.concat(name, ": count mismatch"));

        for (uint256 i = 0; i < expected.length; i++) {
            bool found;
            for (uint256 j = 0; j < actual.length; j++) {
                if (actual[j] == expected[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, string.concat(name, ": missing account"));
        }
    }

    function _assertHasCode(string memory name, address addr) private view {
        if (addr.code.length == 0) revert DeploymentContractCodeMissing(name, addr);
    }

    function _owner(address contractAddress) private view returns (address) {
        (bool success, bytes memory result) = contractAddress.staticcall(abi.encodeWithSignature("owner()"));
        assertTrue(success, "owner() call failed");
        return abi.decode(result, (address));
    }

    function _pendingOwner(address contractAddress) private view returns (address) {
        (bool success, bytes memory result) = contractAddress.staticcall(abi.encodeWithSignature("pendingOwner()"));
        assertTrue(success, "pendingOwner() call failed");
        return abi.decode(result, (address));
    }
}
