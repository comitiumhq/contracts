// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {OrgRegistry} from "../src/OrgRegistry.sol";
import {JobCommitment} from "../src/JobCommitment.sol";
import {JobFunds} from "../src/JobFunds.sol";
import {IERC3009} from "../src/interfaces/IERC3009.sol";
import {IOrgRegistry} from "../src/interfaces/IOrgRegistry.sol";
import {FeeTier, JobConfig, SlashingTable} from "../src/types/ConfigTypes.sol";
import {
    BaseScript,
    DeploymentConfigHashes,
    DeploymentContractSet,
    DeploymentOrgRegistry,
    DeploymentJobFunds,
    DeploymentJobCommitment,
    InitialDeploymentCatalog
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

/// @title Deploy Full System (OrgRegistry + JobFunds + JobCommitment)
/// @notice Deploys immutable registry, job funds, and initial commitment.
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

    function _defaultJobConfig() internal pure returns (JobConfig memory) {
        return JobConfig({
            minStake: 50_000_000,
            tierCount: 3,
            maxBatchSize: 50,
            maxUnpublishedDuration: uint32(90 days),
            maxPublishedDuration: uint32(365 days),
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
        address deployer,
        address feeRecipient,
        address operator,
        address executor,
        address ownerAddress
    ) internal view {
        if (block.chainid != LOCAL_CHAIN_ID) _assertDeploymentCatalogDoesNotExist();

        _requireNonZeroAddress(deployer, "DEPLOYER_ADDRESS");
        _validateStakeToken(config.expectedStakeToken, config);
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
        address usdc = config.expectedStakeToken;
        address feeRecipient = vm.envAddress("FEE_RECIPIENT_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address executor = vm.envAddress("RELAYER_ADDRESS");
        address ownerAddress = vm.envAddress("OWNER_ADDRESS");
        address[] memory initialOperators = _singleAddressSet(operator);
        address[] memory initialExecutors = _singleAddressSet(executor);
        JobConfig memory jobConfig = _defaultJobConfig();
        FeeTier[] memory feeTiers = _defaultFeeTiers();
        uint96 applicantStakeAmount = 3_000_000;
        uint256 startBlock = block.number;
        string memory gitCommit = vm.envOr("GIT_COMMIT", string(""));

        _preflight(config, deployer, feeRecipient, operator, executor, ownerAddress);

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

        // ── 3. JobFunds ──────────────────────────────────────────
        JobFunds jobFunds =
            new JobFunds(IERC20(usdc), IOrgRegistry(address(registry)), feeRecipient, deployer, address(forwarder));

        console.log("[JobFunds]");
        console.log("  Address:", address(jobFunds));

        // ── 4. JobCommitment ────────────────────────────────────────────
        JobCommitment jc = new JobCommitment(
            IERC20(usdc),
            jobFunds,
            deployer,
            address(forwarder),
            operator,
            executor,
            jobConfig,
            feeTiers,
            applicantStakeAmount
        );

        console.log("[JobCommitment]");
        console.log("  Address:", address(jc));

        // ── 5. Link contracts ───────────────────────────────────────────
        jobFunds.registerJobCommitment(address(jc), jc.commitmentVersion());
        jobFunds.setCurrentJobCommitment(address(jc));
        console.log("");
        console.log("Linked: jobFunds currentJobCommitment = %s", address(jc));

        // ── 6. Transfer ownership ─────────────────────────────────────
        registry.transferOwnership(ownerAddress);
        jobFunds.transferOwnership(ownerAddress);
        jc.transferOwnership(ownerAddress);
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

        // JobFunds
        assertEq(jobFunds.owner(), deployer, "jobFunds: wrong owner");
        assertEq(address(jobFunds.stakeToken()), usdc, "jobFunds: wrong stakeToken");
        assertEq(address(jobFunds.orgRegistry()), address(registry), "jobFunds: wrong registry");
        assertEq(jobFunds.feeRecipient(), feeRecipient, "jobFunds: wrong feeRecipient");
        assertEq(jobFunds.trustedForwarder(), address(forwarder), "jobFunds: wrong forwarder");
        assertEq(jobFunds.currentJobCommitment(), address(jc), "jobFunds: wrong currentJobCommitment");

        // JobCommitment
        assertEq(jc.owner(), deployer, "jc: wrong owner");
        assertEq(address(jc.stakeToken()), usdc, "jc: wrong stakeToken");
        assertTrue(jc.isOperator(operator), "jc: operator not set");
        assertTrue(jc.isExecutor(executor), "jc: executor not set");
        assertFalse(jc.isExecutor(operator), "jc: operator is executor");
        assertFalse(jc.isOperator(executor), "jc: executor is operator");
        assertEq(address(jc.jobFunds()), address(jobFunds), "jc: wrong jobFunds");
        assertEq(jc.trustedForwarder(), address(forwarder), "jc: wrong forwarder");
        assertEq(jc.applicantStakeAmount(), applicantStakeAmount, "jc: wrong applicant stake amount");

        // Ownership transfer
        assertEq(registry.pendingOwner(), ownerAddress, "registry: wrong pendingOwner");
        assertEq(jobFunds.pendingOwner(), ownerAddress, "jobFunds: wrong pendingOwner");
        assertEq(jc.pendingOwner(), ownerAddress, "jc: wrong pendingOwner");
        console.log("Pending owner: %s", ownerAddress);

        console.log("All checks passed!");

        // ── 8. Save deployment catalog ──────────────────────────────────
        InitialDeploymentCatalog memory deploymentCatalog = InitialDeploymentCatalog({
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
                jobFunds: DeploymentJobFunds({
                    address_: address(jobFunds), initialOwner: ownerAddress, initialFeeRecipient: feeRecipient
                }),
                jobCommitment: DeploymentJobCommitment({
                    commitmentVersion: jc.commitmentVersion(),
                    address_: address(jc),
                    startBlock: startBlock,
                    domainSeparator: jc.DOMAIN_SEPARATOR(),
                    runtimeCodeHash: address(jc).codehash,
                    initialOwner: ownerAddress,
                    initialOperators: initialOperators,
                    initialExecutors: initialExecutors,
                    initialConfigHashes: DeploymentConfigHashes({
                        jobConfig: keccak256(abi.encode(jobConfig)),
                        feeTiers: keccak256(abi.encode(feeTiers)),
                        applicantStakeAmount: keccak256(abi.encode(jc.applicantStakeAmount()))
                    })
                })
            })
        });

        if (_shouldSaveDeploymentCatalog()) _saveInitialDeploymentCatalog(deploymentCatalog);
        else console.log("Catalog save skipped: set SAVE_DEPLOYMENT_CATALOG=true to write deployments JSON");

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Catalog path: %s", _deploymentFile());
    }
}
