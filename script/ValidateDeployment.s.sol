// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {OrgRegistry} from "../src/OrgRegistry.sol";
import {JobCommitment} from "../src/JobCommitment.sol";
import {JobFunds} from "../src/JobFunds.sol";
import {IERC3009} from "../src/interfaces/IERC3009.sol";
import {RegisteredJobCommitment} from "../src/interfaces/IJobFunds.sol";
import {FeeTier, JobConfig} from "../src/types/ConfigTypes.sol";
import {
    BaseScript,
    DeploymentConfigHashes,
    DeploymentOrgRegistry,
    DeploymentJobFunds,
    DeploymentJobCommitment,
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
    DeploymentJobFunds jobFunds;
    DeploymentJobCommitment[] jobCommitments;
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

        catalog.jobFunds.address_ = vm.parseJsonAddress(json, string.concat(path, ".contracts.jobFunds.address"));
        catalog.jobFunds.initialOwner =
            vm.parseJsonAddress(json, string.concat(path, ".contracts.jobFunds.initialOwner"));
        catalog.jobFunds.initialFeeRecipient =
            vm.parseJsonAddress(json, string.concat(path, ".contracts.jobFunds.initialFeeRecipient"));
        catalog.jobCommitments = _parseJobCommitments(json, path);
    }

    function _parseJobCommitments(string memory json, string memory deploymentPath)
        private
        pure
        returns (DeploymentJobCommitment[] memory commitments)
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

        commitments = new DeploymentJobCommitment[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory path = _commitmentPath(deploymentPath, i);
            commitments[i] = DeploymentJobCommitment({
                commitmentVersion: uint32(vm.parseJsonUint(json, string.concat(path, ".commitmentVersion"))),
                address_: vm.parseJsonAddress(json, string.concat(path, ".address")),
                startBlock: vm.parseJsonUint(json, string.concat(path, ".startBlock")),
                domainSeparator: vm.parseJsonBytes32(json, string.concat(path, ".domainSeparator")),
                runtimeCodeHash: vm.parseJsonBytes32(json, string.concat(path, ".runtimeCodeHash")),
                initialOwner: vm.parseJsonAddress(json, string.concat(path, ".initialOwner")),
                initialOperators: vm.parseJsonAddressArray(json, string.concat(path, ".initialOperators")),
                initialExecutors: vm.parseJsonAddressArray(json, string.concat(path, ".initialExecutors")),
                initialConfigHashes: DeploymentConfigHashes({
                    jobConfig: vm.parseJsonBytes32(json, string.concat(path, ".initialConfigHashes.jobConfig")),
                    feeTiers: vm.parseJsonBytes32(json, string.concat(path, ".initialConfigHashes.feeTiers"))
                })
            });
        }
    }

    function _commitmentPath(string memory deploymentPath, uint256 index) private pure returns (string memory) {
        return string.concat(deploymentPath, ".contracts.jobCommitments[", vm.toString(index), "]");
    }

    function _assertDeploymentMetadata(ParsedDeploymentCatalog memory catalog) private view {
        assertGt(catalog.deploymentSetVersion, 0, "catalog: deploymentSetVersion is zero");
        assertGt(bytes(catalog.network).length, 0, "catalog: network is empty");
        assertTrue(catalog.deployer != address(0), "catalog: deployer is zero");
        assertGt(catalog.startBlock, 0, "catalog: startBlock is zero");
        assertGe(catalog.deployedAtBlock, catalog.startBlock, "catalog: deployedAtBlock before startBlock");
        assertGt(catalog.deployedAtTimestamp, 0, "catalog: deployedAtTimestamp is zero");
        assertGt(catalog.jobCommitments.length, 0, "catalog: jobCommitments are empty");

        if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            assertGt(bytes(catalog.gitCommit).length, 0, "catalog: mainnet gitCommit is empty");
        }
    }

    function _assertSingletons(ParsedDeploymentCatalog memory catalog) private view {
        _assertHasCode("stakeToken", catalog.stakeToken);
        _assertHasCode("ERC2771Forwarder", catalog.forwarder);
        _assertHasCode("OrgRegistry", catalog.orgRegistry.address_);
        _assertHasCode("JobFunds", catalog.jobFunds.address_);

        bytes32 expectedDomainSeparator = _expectedUsdcDomainSeparator(catalog.stakeToken);
        bytes32 actualDomainSeparator = IERC3009(catalog.stakeToken).DOMAIN_SEPARATOR();
        if (actualDomainSeparator != expectedDomainSeparator) {
            revert DeploymentStakeTokenAuthorizationDomainMismatch(
                catalog.stakeToken, expectedDomainSeparator, actualDomainSeparator
            );
        }

        OrgRegistry orgRegistry = OrgRegistry(catalog.orgRegistry.address_);
        JobFunds jobFunds = JobFunds(catalog.jobFunds.address_);
        assertEq(orgRegistry.trustedForwarder(), catalog.forwarder, "OrgRegistry: forwarder mismatch");
        assertEq(
            orgRegistry.DOMAIN_SEPARATOR(),
            catalog.orgRegistry.domainSeparator,
            "OrgRegistry: domain separator mismatch"
        );
        assertEq(address(jobFunds.stakeToken()), catalog.stakeToken, "JobFunds: stakeToken mismatch");
        assertEq(address(jobFunds.orgRegistry()), catalog.orgRegistry.address_, "JobFunds: orgRegistry mismatch");
        assertEq(jobFunds.trustedForwarder(), catalog.forwarder, "JobFunds: forwarder mismatch");
    }

    function _assertCommitments(ParsedDeploymentCatalog memory catalog) private view {
        JobFunds jobFunds = JobFunds(catalog.jobFunds.address_);
        address current = jobFunds.currentJobCommitment();
        bool currentFound;

        for (uint256 i = 0; i < catalog.jobCommitments.length; i++) {
            DeploymentJobCommitment memory entry = catalog.jobCommitments[i];
            assertGt(entry.commitmentVersion, 0, "catalog: commitmentVersion is zero");
            assertGt(entry.startBlock, 0, "catalog: JobCommitment startBlock is zero");
            _assertHasCode("JobCommitment", entry.address_);
            assertEq(entry.address_.codehash, entry.runtimeCodeHash, "JobCommitment: runtime code hash mismatch");

            for (uint256 j = 0; j < i; j++) {
                if (catalog.jobCommitments[j].address_ == entry.address_) {
                    revert DeploymentCatalogDuplicateCommitment(entry.address_);
                }
            }

            JobCommitment commitment = JobCommitment(entry.address_);
            RegisteredJobCommitment memory registration = jobFunds.registeredJobCommitment(entry.address_);
            assertTrue(registration.exists, "JobFunds: JobCommitment not registered");
            assertEq(
                registration.commitmentVersion,
                entry.commitmentVersion,
                "JobFunds: registered commitment version mismatch"
            );
            assertEq(commitment.commitmentVersion(), entry.commitmentVersion, "JobCommitment: version mismatch");
            assertEq(address(commitment.jobFunds()), catalog.jobFunds.address_, "JobCommitment: jobFunds mismatch");
            assertEq(commitment.trustedForwarder(), catalog.forwarder, "JobCommitment: forwarder mismatch");
            assertEq(commitment.DOMAIN_SEPARATOR(), entry.domainSeparator, "JobCommitment: domain mismatch");

            if (entry.address_ == current) currentFound = true;
        }

        if (!currentFound) revert DeploymentCatalogMissingCurrentCommitment(current);
    }

    function _assertInitialSnapshots(ParsedDeploymentCatalog memory catalog) private view {
        OrgRegistry orgRegistry = OrgRegistry(catalog.orgRegistry.address_);
        JobFunds jobFunds = JobFunds(catalog.jobFunds.address_);

        _assertAcceptedOwnership("OrgRegistry", catalog.orgRegistry.address_, catalog.orgRegistry.initialOwner);
        _assertAcceptedOwnership("JobFunds", catalog.jobFunds.address_, catalog.jobFunds.initialOwner);
        _assertSameAddressSet(
            "OrgRegistry initial operators", orgRegistry.operators(), catalog.orgRegistry.initialOperators
        );
        assertEq(
            jobFunds.feeRecipient(), catalog.jobFunds.initialFeeRecipient, "JobFunds: initial fee recipient mismatch"
        );

        for (uint256 i = 0; i < catalog.jobCommitments.length; i++) {
            DeploymentJobCommitment memory entry = catalog.jobCommitments[i];
            JobCommitment commitment = JobCommitment(entry.address_);
            JobConfig memory config = commitment.jobConfig(1);
            FeeTier[] memory tiers = commitment.feeTiers(1);

            _assertAcceptedOwnership("JobCommitment", entry.address_, entry.initialOwner);
            _assertDisjointRoles(entry.initialOperators, entry.initialExecutors);
            _assertSameAddressSet("JobCommitment initial operators", commitment.operators(), entry.initialOperators);
            _assertSameAddressSet("JobCommitment initial executors", commitment.executors(), entry.initialExecutors);
            assertEq(
                keccak256(abi.encode(config)),
                entry.initialConfigHashes.jobConfig,
                "JobCommitment: initial job config hash mismatch"
            );
            assertEq(
                keccak256(abi.encode(tiers)),
                entry.initialConfigHashes.feeTiers,
                "JobCommitment: initial fee tiers hash mismatch"
            );
        }
    }

    function _assertConfiguredRoles(ParsedDeploymentCatalog memory catalog) internal view {
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address executor = vm.envAddress("RELAYER_ADDRESS");

        _assertContainsAddress("operator", OrgRegistry(catalog.orgRegistry.address_).operators(), operator);

        for (uint256 i = 0; i < catalog.jobCommitments.length; i++) {
            JobCommitment commitment = JobCommitment(catalog.jobCommitments[i].address_);
            _assertContainsAddress("JobCommitment operator", commitment.operators(), operator);
            _assertContainsAddress("JobCommitment executor", commitment.executors(), executor);
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
