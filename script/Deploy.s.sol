// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {OrgRegistry} from "../src/OrgRegistry.sol";
import {ResponseCommitment} from "../src/ResponseCommitment.sol";
import {CommitmentFunds} from "../src/CommitmentFunds.sol";
import {IERC3009} from "../src/interfaces/IERC3009.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {FeeTier, CommitmentConfig, SlashingTable} from "../src/types/ConfigTypes.sol";
import {
    BaseScript,
    DeploymentConfigHashes,
    DeploymentContractSet,
    DeploymentOrgRegistry,
    DeploymentCommitmentFunds,
    DeploymentResponseCommitment,
    DeploymentCatalog
} from "./Base.s.sol";

error UnsupportedChain(uint256 chainId);
error UnexpectedStakeToken(uint256 chainId, address expected, address actual);
error StakeTokenNotContract(address token);
error StakeTokenDecimalsUnavailable(address token);
error StakeTokenDecimalsMismatch(address token, uint8 expected, uint8 actual);
error StakeTokenAuthorizationUnavailable(address token);
error StakeTokenAuthorizationDomainMismatch(address token, bytes32 expected, bytes32 actual);
error ZeroDeployAddress(string envVar);
error MainnetOwnerMustBeContract(address owner);
error MainnetOwnerMatchesDeployer(address owner);
error MainnetOperatorMatchesDeployer(address operator);
error MainnetExecutorMatchesDeployer(address executor);
error ProtocolRolesOverlap(address account);
error MainnetGitCommitRequired();
error FeeRecipientMatchesOwner(address account);

/// @title Deploy Comitium contracts
/// @notice Deploys one complete immutable contract set.
/// @dev
///   forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
///   forge script script/Deploy.s.sol --rpc-url $BASE_MAINNET_RPC_URL --account $DEPLOYER_ACCOUNT --broadcast --verify
contract Deploy is BaseScript, Test {
    uint256 private constant LOCAL_CHAIN_ID = 31337;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 private constant BASE_MAINNET_CHAIN_ID = 8453;
    uint8 private constant EXPECTED_STAKE_TOKEN_DECIMALS = 6;

    address private constant BASE_SEPOLIA_MOCK_USDC = 0x61479Fd8c77084d715D72A1E417fd48A92002819;
    address private constant BASE_MAINNET_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    struct ChainDeployConfig {
        string network;
        address expectedStakeToken;
        bool isMainnet;
    }

    function _defaultCommitmentConfig() internal pure returns (CommitmentConfig memory) {
        return CommitmentConfig({
            minStake: 50_000_000,
            tierCount: 3,
            maxBatchSize: 50,
            maxStoppedDuration: uint32(90 days),
            maxActiveDuration: uint32(365 days),
            harshSlashing: SlashingTable({
                zeroResponseRate: 10000,
                below50Rate: 5000,
                rate50: 3500,
                rate60: 2500,
                rate70: 1800,
                rate80: 1000,
                rate90: 500,
                rate95: 200
            }),
            softSlashing: SlashingTable({
                zeroResponseRate: 3000,
                below50Rate: 2500,
                rate50: 2200,
                rate60: 1800,
                rate70: 1200,
                rate80: 800,
                rate90: 500,
                rate95: 200
            })
        });
    }

    function _defaultFeeTiers() internal pure returns (FeeTier[] memory tiers) {
        tiers = new FeeTier[](3);
        tiers[0] = FeeTier({baseFee: 25_000_000, feeBps: 150, deadlineDays: 3});
        tiers[1] = FeeTier({baseFee: 35_000_000, feeBps: 250, deadlineDays: 7});
        tiers[2] = FeeTier({baseFee: 50_000_000, feeBps: 350, deadlineDays: 14});
    }

    function _chainDeployConfig() internal view returns (ChainDeployConfig memory) {
        if (block.chainid == LOCAL_CHAIN_ID) {
            return ChainDeployConfig({network: "local", expectedStakeToken: address(0), isMainnet: false});
        }

        if (block.chainid == BASE_SEPOLIA_CHAIN_ID) {
            return
                ChainDeployConfig({
                    network: "base_sepolia", expectedStakeToken: BASE_SEPOLIA_MOCK_USDC, isMainnet: false
                });
        }

        if (block.chainid == BASE_MAINNET_CHAIN_ID) {
            return ChainDeployConfig({network: "base_mainnet", expectedStakeToken: BASE_MAINNET_USDC, isMainnet: true});
        }

        revert UnsupportedChain(block.chainid);
    }

    function _singleAddressSet(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _requireNonZeroAddress(address addr, string memory envVar) internal pure {
        if (addr == address(0)) revert ZeroDeployAddress(envVar);
    }

    function _validateStakeToken(address usdc, ChainDeployConfig memory config) internal view {
        if (config.expectedStakeToken != address(0) && usdc != config.expectedStakeToken) {
            revert UnexpectedStakeToken(block.chainid, config.expectedStakeToken, usdc);
        }

        if (usdc.code.length == 0) revert StakeTokenNotContract(usdc);

        try IERC20Metadata(usdc).decimals() returns (uint8 decimals_) {
            if (decimals_ != EXPECTED_STAKE_TOKEN_DECIMALS) {
                revert StakeTokenDecimalsMismatch(usdc, EXPECTED_STAKE_TOKEN_DECIMALS, decimals_);
            }
        } catch {
            revert StakeTokenDecimalsUnavailable(usdc);
        }

        try IERC3009(usdc).DOMAIN_SEPARATOR() returns (bytes32 domainSeparator) {
            bytes32 expected = _expectedUsdcDomainSeparator(usdc);

            if (domainSeparator != expected) {
                revert StakeTokenAuthorizationDomainMismatch(usdc, expected, domainSeparator);
            }
        } catch {
            revert StakeTokenAuthorizationUnavailable(usdc);
        }
    }

    function _validateMainnetRoleSeparation(address deployer, address ownerAddress, address operator, address executor)
        internal
        view
    {
        if (ownerAddress == deployer) revert MainnetOwnerMatchesDeployer(ownerAddress);
        if (ownerAddress.code.length == 0) revert MainnetOwnerMustBeContract(ownerAddress);
        if (operator == deployer) revert MainnetOperatorMatchesDeployer(operator);
        if (executor == deployer) revert MainnetExecutorMatchesDeployer(executor);
    }

    function _validateProtocolRoles(address operator, address executor) internal pure {
        _requireNonZeroAddress(operator, "OPERATOR_ADDRESS");
        _requireNonZeroAddress(executor, "RELAYER_ADDRESS");

        if (operator == executor) revert ProtocolRolesOverlap(operator);
    }

    function _validateFeeRecipient(address feeRecipient, address ownerAddress) internal pure {
        if (feeRecipient == ownerAddress) revert FeeRecipientMatchesOwner(feeRecipient);
    }

    function _validateMainnetGitCommit() internal view {
        string memory gitCommit = vm.envOr("GIT_COMMIT", string(""));

        if (bytes(gitCommit).length == 0) revert MainnetGitCommitRequired();
    }

    function _preflight(
        ChainDeployConfig memory config,
        address usdc,
        address deployer,
        address feeRecipient,
        address operator,
        address executor,
        address ownerAddress
    ) internal view {
        if (block.chainid != LOCAL_CHAIN_ID) _assertDeploymentCatalogDoesNotExist();

        _requireNonZeroAddress(deployer, "DEPLOYER_ADDRESS");
        _validateStakeToken(usdc, config);
        _requireNonZeroAddress(feeRecipient, "FEE_RECIPIENT_ADDRESS");
        _requireNonZeroAddress(ownerAddress, "OWNER_ADDRESS");
        _validateFeeRecipient(feeRecipient, ownerAddress);
        _validateProtocolRoles(operator, executor);

        if (_shouldSaveDeploymentCatalog() && _isScriptDryRun()) _assertDeploymentCatalogWriteAllowed();

        if (config.isMainnet) {
            _validateMainnetRoleSeparation(deployer, ownerAddress, operator, executor);
            _validateMainnetGitCommit();
        }
    }

    function run() external {
        // ── Config ──────────────────────────────────────────────────────
        ChainDeployConfig memory config = _chainDeployConfig();
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address usdc =
            config.expectedStakeToken == address(0) ? vm.envAddress("STAKE_TOKEN_ADDRESS") : config.expectedStakeToken;
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address executor = vm.envAddress("RELAYER_ADDRESS");
        address ownerAddress = vm.envAddress("OWNER_ADDRESS");
        address[] memory initialOperators = _singleAddressSet(operator);
        address[] memory initialExecutors = _singleAddressSet(executor);
        CommitmentConfig memory commitmentConfig = _defaultCommitmentConfig();
        FeeTier[] memory feeTiers = _defaultFeeTiers();
        uint256 startBlock = block.number;
        string memory gitCommit = vm.envOr("GIT_COMMIT", string(""));

        _preflight(config, usdc, deployer, feeRecipient, operator, executor, ownerAddress);

        console.log("=== Deploying Comitium ===");
        console.log("Chain ID:", block.chainid);
        console.log("Network profile:", config.network);
        console.log("Deployer:", deployer);
        console.log("Owner:", ownerAddress);
        console.log("USDC:", usdc);
        console.log("Fee recipient:", feeRecipient);
        console.log("Operator:", operator);
        console.log("Executor:", executor);
        console.log("");

        vm.startBroadcast(deployer);

        // ── 1. ERC-2771 forwarder ────────────────────────────────────
        ERC2771Forwarder forwarder = new ERC2771Forwarder("ComitiumForwarder");

        console.log("[ERC2771Forwarder]");
        console.log("  Address:", address(forwarder));

        // ── 2. OrgRegistry ─────────────────────────────────────
        OrgRegistry registry = new OrgRegistry(deployer, address(forwarder), operator);

        console.log("[OrgRegistry]");
        console.log("  Address:", address(registry));

        // ── 3. CommitmentFunds ───────────────────────────────────
        CommitmentFunds commitmentFunds = new CommitmentFunds(
            IERC20(usdc), IOrgRegistry(address(registry)), feeRecipient, deployer, address(forwarder)
        );

        console.log("[CommitmentFunds]");
        console.log("  Address:", address(commitmentFunds));

        // ── 4. ResponseCommitment ────────────────────────────────
        ResponseCommitment commitment = new ResponseCommitment(
            commitmentFunds, deployer, address(forwarder), operator, executor, commitmentConfig, feeTiers
        );

        console.log("[ResponseCommitment]");
        console.log("  Address:", address(commitment));

        // ── 5. Link contracts ───────────────────────────────────────────
        commitmentFunds.registerResponseCommitment(address(commitment), commitment.commitmentVersion());
        commitmentFunds.setCurrentResponseCommitment(address(commitment));
        console.log("");
        console.log("Linked: commitmentFunds currentResponseCommitment = %s", address(commitment));

        // ── 6. Transfer ownership ─────────────────────────────────────
        registry.transferOwnership(ownerAddress);
        commitmentFunds.transferOwnership(ownerAddress);
        commitment.transferOwnership(ownerAddress);
        console.log("");
        console.log("Ownership transfer initiated to: %s", ownerAddress);
        console.log(">> Owner must call acceptOwnership() on all contracts to complete");

        vm.stopBroadcast();

        // ── 7. Post-deploy verification ─────────────────────────────────
        console.log("");
        console.log("Running post-deploy checks...");

        // OrgRegistry
        assertEq(registry.owner(), deployer, "registry: wrong owner");
        assertEq(registry.trustedForwarder(), address(forwarder), "registry: wrong forwarder");
        assertTrue(registry.isOperator(operator), "registry: operator not set");

        // CommitmentFunds
        assertEq(commitmentFunds.owner(), deployer, "commitmentFunds: wrong owner");
        assertEq(address(commitmentFunds.stakeToken()), usdc, "commitmentFunds: wrong stakeToken");
        assertEq(address(commitmentFunds.orgRegistry()), address(registry), "commitmentFunds: wrong registry");
        assertEq(commitmentFunds.feeRecipient(), feeRecipient, "commitmentFunds: wrong feeRecipient");
        assertEq(commitmentFunds.trustedForwarder(), address(forwarder), "commitmentFunds: wrong forwarder");
        assertEq(
            commitmentFunds.currentResponseCommitment(),
            address(commitment),
            "commitmentFunds: wrong currentResponseCommitment"
        );

        // ResponseCommitment
        assertEq(commitment.owner(), deployer, "commitment: wrong owner");
        assertTrue(commitment.isOperator(operator), "commitment: operator not set");
        assertTrue(commitment.isExecutor(executor), "commitment: executor not set");
        assertFalse(commitment.isExecutor(operator), "commitment: operator is executor");
        assertFalse(commitment.isOperator(executor), "commitment: executor is operator");
        assertEq(address(commitment.commitmentFunds()), address(commitmentFunds), "commitment: wrong commitmentFunds");
        assertEq(commitment.trustedForwarder(), address(forwarder), "commitment: wrong forwarder");

        // Ownership transfer
        assertEq(registry.pendingOwner(), ownerAddress, "registry: wrong pendingOwner");
        assertEq(commitmentFunds.pendingOwner(), ownerAddress, "commitmentFunds: wrong pendingOwner");
        assertEq(commitment.pendingOwner(), ownerAddress, "commitment: wrong pendingOwner");
        console.log("Pending owner: %s", ownerAddress);

        console.log("All checks passed!");

        // ── 8. Save deployment catalog ──────────────────────────────────
        DeploymentCatalog memory deploymentCatalog = DeploymentCatalog({
            deploymentSetVersion: 1,
            network: config.network,
            deployer: deployer,
            stakeToken: usdc,
            startBlock: startBlock,
            deployedAtBlock: block.number,
            deployedAtTimestamp: block.timestamp,
            gitCommit: gitCommit,
            contracts_: DeploymentContractSet({
                forwarder: address(forwarder),
                orgRegistry: DeploymentOrgRegistry({
                    address_: address(registry),
                    domainSeparator: registry.DOMAIN_SEPARATOR(),
                    initialOwner: ownerAddress,
                    initialOperators: initialOperators
                }),
                commitmentFunds: DeploymentCommitmentFunds({
                    address_: address(commitmentFunds), initialOwner: ownerAddress, initialFeeRecipient: feeRecipient
                }),
                responseCommitment: DeploymentResponseCommitment({
                    commitmentVersion: commitment.commitmentVersion(),
                    address_: address(commitment),
                    startBlock: startBlock,
                    domainSeparator: commitment.DOMAIN_SEPARATOR(),
                    runtimeCodeHash: address(commitment).codehash,
                    initialOwner: ownerAddress,
                    initialOperators: initialOperators,
                    initialExecutors: initialExecutors,
                    initialConfigHashes: DeploymentConfigHashes({
                        commitmentConfig: keccak256(abi.encode(commitmentConfig)),
                        feeTiers: keccak256(abi.encode(feeTiers))
                    })
                })
            })
        });

        if (_shouldSaveDeploymentCatalog()) _saveDeploymentCatalog(deploymentCatalog);
        else console.log("Catalog save skipped: set SAVE_DEPLOYMENT_CATALOG=true to write deployments JSON");

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Catalog path: %s", _deploymentFile());
    }
}
