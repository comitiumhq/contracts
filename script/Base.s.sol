// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

error DeploymentCatalogAlreadyExists(string path);
error DeploymentCatalogSaveDisabled();
error DeploymentCatalogWriteDuringDryRun(string path);
error UnsupportedDeploymentCatalogSchema(uint256 schemaVersion);

struct DeploymentConfigHashes {
    bytes32 commitmentConfig;
    bytes32 feeTiers;
}

struct DeploymentOrgRegistry {
    address address_;
    bytes32 domainSeparator;
    address initialOwner;
    address[] initialOperators;
}

struct DeploymentCommitmentFunds {
    address address_;
    address initialOwner;
    address initialFeeRecipient;
}

struct DeploymentResponseCommitment {
    uint32 commitmentVersion;
    address address_;
    uint256 startBlock;
    bytes32 domainSeparator;
    bytes32 runtimeCodeHash;
    address initialOwner;
    address[] initialOperators;
    address[] initialExecutors;
    DeploymentConfigHashes initialConfigHashes;
}

struct DeploymentContractSet {
    address forwarder;
    DeploymentOrgRegistry orgRegistry;
    DeploymentCommitmentFunds commitmentFunds;
    DeploymentResponseCommitment responseCommitment;
}

struct DeploymentCatalog {
    uint256 deploymentSetVersion;
    string network;
    address deployer;
    address stakeToken;
    uint256 startBlock;
    uint256 deployedAtBlock;
    uint256 deployedAtTimestamp;
    string gitCommit;
    DeploymentContractSet contracts_;
}

/// @title Base Deploy Script
/// @notice Deployment catalog serialization for `deployments/deployment-catalog.json`.
abstract contract BaseScript is Script {
    uint256 internal constant DEPLOYMENT_CATALOG_SCHEMA_VERSION = 1;
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant USDC_NAME_HASH = keccak256("USD Coin");
    bytes32 private constant USDC_VERSION_HASH = keccak256("2");

    function _expectedUsdcDomainSeparator(address token) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, USDC_NAME_HASH, USDC_VERSION_HASH, block.chainid, token));
    }

    function _deploymentFile() internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/deployment-catalog.json");
    }

    function _deploymentPath() internal view returns (string memory) {
        return string.concat(".deployments.", vm.toString(block.chainid));
    }

    function _shouldSaveDeploymentCatalog() internal view returns (bool) {
        return vm.envOr("SAVE_DEPLOYMENT_CATALOG", false);
    }

    function _isScriptDryRun() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptDryRun);
    }

    function _assertDeploymentCatalogDoesNotExist() internal view {
        string memory file = _deploymentFile();

        if (!vm.exists(file)) return;

        string memory json = vm.readFile(file);
        uint256 schemaVersion = vm.parseJsonUint(json, ".schemaVersion");
        if (schemaVersion != DEPLOYMENT_CATALOG_SCHEMA_VERSION) {
            revert UnsupportedDeploymentCatalogSchema(schemaVersion);
        }
        if (vm.keyExistsJson(json, _deploymentPath())) revert DeploymentCatalogAlreadyExists(file);
    }

    function _assertDeploymentCatalogWriteAllowed() internal view {
        string memory file = _deploymentFile();

        if (!_shouldSaveDeploymentCatalog()) revert DeploymentCatalogSaveDisabled();
        if (_isScriptDryRun()) revert DeploymentCatalogWriteDuringDryRun(file);
    }

    function _saveDeployment(string memory json) internal {
        string memory dir = string.concat(vm.projectRoot(), "/deployments");
        string memory file = _deploymentFile();

        _assertDeploymentCatalogWriteAllowed();

        if (!vm.isDir(dir)) vm.createDir(dir, true);
        _assertDeploymentCatalogDoesNotExist();
        if (!vm.exists(file)) {
            vm.writeJson(
                string.concat(
                    '{"schemaVersion":', vm.toString(DEPLOYMENT_CATALOG_SCHEMA_VERSION), ',"deployments":{}}'
                ),
                file
            );
        }

        vm.writeJson(json, file, _deploymentPath());
    }

    function _saveDeploymentCatalog(DeploymentCatalog memory catalog) internal {
        _saveDeployment(_deploymentCatalogJson(catalog));
    }

    function _deploymentCatalogJson(DeploymentCatalog memory catalog) private pure returns (string memory) {
        return string.concat(
            '{"deploymentSetVersion":',
            vm.toString(catalog.deploymentSetVersion),
            ',"network":',
            _quoted(catalog.network),
            ',"deployer":',
            _quoted(vm.toString(catalog.deployer)),
            ',"stakeToken":',
            _quoted(vm.toString(catalog.stakeToken)),
            ',"startBlock":',
            vm.toString(catalog.startBlock),
            ',"deployedAtBlock":',
            vm.toString(catalog.deployedAtBlock),
            ',"deployedAtTimestamp":',
            vm.toString(catalog.deployedAtTimestamp),
            ',"gitCommit":',
            _quoted(catalog.gitCommit),
            ',"script":"script/Deploy.s.sol","contracts":',
            _contractsJson(catalog.contracts_),
            "}"
        );
    }

    function _contractsJson(DeploymentContractSet memory contracts_) private pure returns (string memory) {
        return string.concat(
            '{"forwarder":',
            _quoted(vm.toString(contracts_.forwarder)),
            ',"orgRegistry":',
            _orgRegistryJson(contracts_.orgRegistry),
            ',"commitmentFunds":',
            _commitmentFundsJson(contracts_.commitmentFunds),
            ',"responseCommitments":[',
            _responseCommitmentJson(contracts_.responseCommitment),
            "]}"
        );
    }

    function _orgRegistryJson(DeploymentOrgRegistry memory registry) private pure returns (string memory) {
        return string.concat(
            '{"address":',
            _quoted(vm.toString(registry.address_)),
            ',"domainSeparator":',
            _quoted(vm.toString(registry.domainSeparator)),
            ',"initialOwner":',
            _quoted(vm.toString(registry.initialOwner)),
            ',"initialOperators":',
            _addressArrayJson(registry.initialOperators),
            "}"
        );
    }

    function _commitmentFundsJson(DeploymentCommitmentFunds memory funds) private pure returns (string memory) {
        return string.concat(
            '{"address":',
            _quoted(vm.toString(funds.address_)),
            ',"initialOwner":',
            _quoted(vm.toString(funds.initialOwner)),
            ',"initialFeeRecipient":',
            _quoted(vm.toString(funds.initialFeeRecipient)),
            "}"
        );
    }

    function _responseCommitmentJson(DeploymentResponseCommitment memory commitment)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"commitmentVersion":',
            vm.toString(commitment.commitmentVersion),
            ',"address":',
            _quoted(vm.toString(commitment.address_)),
            ',"startBlock":',
            vm.toString(commitment.startBlock),
            ',"domainSeparator":',
            _quoted(vm.toString(commitment.domainSeparator)),
            ',"runtimeCodeHash":',
            _quoted(vm.toString(commitment.runtimeCodeHash)),
            ',"initialOwner":',
            _quoted(vm.toString(commitment.initialOwner)),
            ',"initialOperators":',
            _addressArrayJson(commitment.initialOperators),
            ',"initialExecutors":',
            _addressArrayJson(commitment.initialExecutors),
            ',"initialConfigHashes":',
            _configHashesJson(commitment.initialConfigHashes),
            "}"
        );
    }

    function _configHashesJson(DeploymentConfigHashes memory hashes) private pure returns (string memory) {
        return string.concat(
            '{"commitmentConfig":',
            _quoted(vm.toString(hashes.commitmentConfig)),
            ',"feeTiers":',
            _quoted(vm.toString(hashes.feeTiers)),
            "}"
        );
    }

    function _addressArrayJson(address[] memory addresses) private pure returns (string memory) {
        string memory json = "[";

        for (uint256 i = 0; i < addresses.length; i++) {
            if (i > 0) json = string.concat(json, ",");

            json = string.concat(json, _quoted(vm.toString(addresses[i])));
        }

        return string.concat(json, "]");
    }

    function _quoted(string memory value) private pure returns (string memory) {
        return string.concat('"', value, '"');
    }
}
