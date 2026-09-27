// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ResponseCommitment} from "../../src/ResponseCommitment.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {CommitmentFunds} from "../../src/CommitmentFunds.sol";
import {OrgCommitmentBalance} from "../../src/interfaces/ICommitmentFunds.sol";
import {CommitmentView, ApplicationView} from "../../src/interfaces/IResponseCommitment.sol";
import {CommitmentStatus} from "../../src/types/CommitmentTypes.sol";

import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";

import {USDC} from "../mocks/USDC.sol";
import {Eip3009TestHelper} from "./Eip3009TestHelper.sol";
import {SLASH_BURN_ADDRESS as PROTOCOL_SLASH_BURN_ADDRESS} from "../../src/Constants.sol";
import {FeeTier, CommitmentConfig, SlashingTable} from "../../src/types/ConfigTypes.sol";
import {CommitmentAuthorizationLib} from "../../src/libraries/CommitmentAuthorizationLib.sol";
import {OrgAuthorizationLib} from "../../src/libraries/OrgAuthorizationLib.sol";

// ============ Test Constants ============
uint256 constant TEST_MIN_STAKE = 50_000_000;
uint96 constant TEST_TIER_0_BASE_FEE = 25_000_000;
uint96 constant TEST_TIER_1_BASE_FEE = 35_000_000;
uint96 constant TEST_TIER_2_BASE_FEE = 50_000_000;
uint256 constant TEST_MAX_STOPPED_DURATION = 90 days;
uint256 constant TEST_MAX_ACTIVE_DURATION = 365 days;
uint256 constant TEST_FEE_TIER_0 = 150;
uint256 constant TEST_FEE_TIER_1 = 250;
uint256 constant TEST_FEE_TIER_2 = 350;
uint8 constant TEST_DEADLINE_DAYS_TIER_0 = 3;
uint8 constant TEST_DEADLINE_DAYS_TIER_1 = 7;
uint8 constant TEST_DEADLINE_DAYS_TIER_2 = 14;

/// @title ResponseCommitmentTestBase
/// @notice Base contract for all ResponseCommitment tests with common setup and helpers
abstract contract ResponseCommitmentTestBase is Eip3009TestHelper {
    using MessageHashUtils for bytes32;

    // ============ Contracts ============
    ResponseCommitment public responseCommitment;
    OrgRegistry public orgRegistry;
    CommitmentFunds public commitmentFunds;
    ERC2771Forwarder public forwarder;
    USDC public usdc;

    // ============ Actors ============
    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");
    uint256 public employerPrivateKey = 0xE11CE;
    address public employer;
    address public applicant1 = makeAddr("applicant1");
    address public applicant2 = makeAddr("applicant2");

    // ============ Protocol Roles ============
    uint256 public operatorPrivateKey = 0x1234;
    address public operator;
    uint256 public executorPrivateKey = 0x5678;
    address public executor;

    // ============ Constants ============
    uint256 public constant EMPLOYER_STAKE = 500_000_000; // 500 USDC
    uint256 public constant DEFAULT_ORG_ID = 1;
    uint256 public constant ORG_OPERATIONAL_BALANCE = 100_000_000_000; // 100,000 USDC
    uint8 public constant DEFAULT_RESPONSE_DEADLINE_DAYS = 3; // tier 0
    bytes32 public constant DEFAULT_POSTING_REF = keccak256("comitium:test:posting");
    address public constant SLASH_BURN_ADDRESS = PROTOCOL_SLASH_BURN_ADDRESS;

    // ============ Nonces ============
    uint256 public applicationNonce;
    uint256 public settleNonce;
    uint256 public expiredSettlementNonce;
    uint256 public creationNonce;
    uint256 public domainVerificationNonce;
    uint256 public orgDomainUpdateNonce;
    uint256 public stopNonce;

    uint16 internal constant NONCE_SCOPE_COMMITMENT_ACTIVATION =
        CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_ACTIVATION;
    uint16 internal constant NONCE_SCOPE_COMMITMENT_SETTLEMENT =
        CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_SETTLEMENT;
    uint16 internal constant NONCE_SCOPE_DOMAIN_VERIFICATION = OrgAuthorizationLib.NONCE_SCOPE_DOMAIN_VERIFICATION;
    uint16 internal constant NONCE_SCOPE_COMMITMENT_STOP = CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_STOP;
    uint16 internal constant NONCE_SCOPE_ORG_DOMAIN_UPDATE = OrgAuthorizationLib.NONCE_SCOPE_ORG_DOMAIN_UPDATE;
    uint16 internal constant NONCE_SCOPE_EXPIRED_COMMITMENT_SETTLEMENT =
        CommitmentAuthorizationLib.NONCE_SCOPE_EXPIRED_COMMITMENT_SETTLEMENT;

    // ============ EIP-712 ============
    bytes32 public constant APPLICATION_TYPEHASH = CommitmentAuthorizationLib.APPLICATION_TYPEHASH;
    bytes32 public constant COMMITMENT_SETTLEMENT_TYPEHASH = CommitmentAuthorizationLib.COMMITMENT_SETTLEMENT_TYPEHASH;
    bytes32 public constant EXPIRED_COMMITMENT_SETTLEMENT_TYPEHASH =
        CommitmentAuthorizationLib.EXPIRED_COMMITMENT_SETTLEMENT_TYPEHASH;
    bytes32 public constant COMMITMENT_ACTIVATION_TYPEHASH = CommitmentAuthorizationLib.COMMITMENT_ACTIVATION_TYPEHASH;
    bytes32 public constant COMMITMENT_STOP_TYPEHASH = CommitmentAuthorizationLib.COMMITMENT_STOP_TYPEHASH;
    bytes32 public constant DOMAIN_VERIFICATION_TYPEHASH = OrgAuthorizationLib.DOMAIN_VERIFICATION_TYPEHASH;
    bytes32 public constant ORG_DOMAIN_UPDATE_TYPEHASH = OrgAuthorizationLib.ORG_DOMAIN_UPDATE_TYPEHASH;

    // ============ Config Helpers ============

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
        tiers[0] = FeeTier({baseFee: TEST_TIER_0_BASE_FEE, feeBps: 150, deadlineDays: 3});
        tiers[1] = FeeTier({baseFee: TEST_TIER_1_BASE_FEE, feeBps: 250, deadlineDays: 7});
        tiers[2] = FeeTier({baseFee: TEST_TIER_2_BASE_FEE, feeBps: 350, deadlineDays: 14});
    }

    // ============ Setup ============

    function setUp() public virtual {
        operator = vm.addr(operatorPrivateKey);
        executor = vm.addr(executorPrivateKey);
        employer = vm.addr(employerPrivateKey);
        vm.label(employer, "employer");

        usdc = new USDC();
        forwarder = new ERC2771Forwarder("ComitiumForwarder");

        orgRegistry = new OrgRegistry(owner, address(forwarder), operator, executor);

        commitmentFunds = new CommitmentFunds(
            IERC20(address(usdc)), IOrgRegistry(address(orgRegistry)), feeRecipient, owner, address(forwarder)
        );

        responseCommitment = new ResponseCommitment(
            commitmentFunds,
            owner,
            address(forwarder),
            operator,
            executor,
            _defaultCommitmentConfig(),
            _defaultFeeTiers()
        );

        uint32 commitmentVersion = responseCommitment.commitmentVersion();
        vm.prank(owner);
        commitmentFunds.registerResponseCommitment(address(responseCommitment), commitmentVersion);

        vm.prank(owner);
        commitmentFunds.setCurrentResponseCommitment(address(responseCommitment));

        _createOrgForEmployer(employer, "test.com", DEFAULT_ORG_ID);

        _fundAndDepositWithAuthorization(
            commitmentFunds, address(usdc), employerPrivateKey, DEFAULT_ORG_ID, ORG_OPERATIONAL_BALANCE
        );
    }

    // ============ Organization Helpers ============

    /// @notice Create an organization for a given employer address
    function _createOrgForEmployer(address employerAddr, string memory domain, uint256 expectedOrgId) internal {
        uint256 keyNonce = _nextDomainVerificationKeyNonce(expectedOrgId);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 structHash =
            keccak256(abi.encode(DOMAIN_VERIFICATION_TYPEHASH, _domainHash(domain), employerAddr, keyNonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", orgRegistry.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(executor);
        orgRegistry.createOrg(employerAddr, _domainHash(domain), keyNonce, expiry, sig);
    }

    function _domainHash(string memory domain) internal pure returns (bytes32) {
        return keccak256(bytes(domain));
    }

    /// @notice Fund an org with operational balance
    function _fundOrg(uint256 orgId, uint256 treasuryPrivateKey, uint256 amount) internal {
        _fundAndDepositWithAuthorization(commitmentFunds, address(usdc), treasuryPrivateKey, orgId, amount);
    }

    // ============ Funding Helpers ============

    function _assertSlashBurned(
        uint256 burnAddressBefore,
        uint256 feeRecipientBefore,
        uint256 expectedSlash,
        string memory message
    ) internal view {
        assertEq(usdc.balanceOf(SLASH_BURN_ADDRESS) - burnAddressBefore, expectedSlash, message);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore, "Fee recipient should not receive slash");
    }

    // ============ Commitment Helpers ============

    /// @notice Create a commitment with default stake and specified fee tier
    function _activateCommitment(uint8 feeTier) internal returns (uint256 commitmentId) {
        return _activateCommitmentWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, feeTier, DEFAULT_POSTING_REF);
    }

    /// @notice Create a commitment with all parameters
    function _activateCommitmentWithParams(uint256 orgId, uint256 stake, uint8 feeTier, bytes32 postingRef)
        internal
        returns (uint256 commitmentId)
    {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signCommitmentActivation(orgId, stake, feeTier, postingRef, employer, keyNonce, expiry);
        return _executeCommitmentActivation(employer, orgId, stake, feeTier, postingRef, keyNonce, expiry, signature);
    }

    /// @notice Create a commitment with custom employer
    function _activateCommitmentAs(address employerAddr, uint256 orgId, uint256 stake, uint8 feeTier)
        internal
        returns (uint256 commitmentId)
    {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signCommitmentActivation(orgId, stake, feeTier, DEFAULT_POSTING_REF, employerAddr, keyNonce, expiry);
        return _executeCommitmentActivation(
            employerAddr, orgId, stake, feeTier, DEFAULT_POSTING_REF, keyNonce, expiry, signature
        );
    }

    function _executeCommitmentActivation(
        address creator,
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        bytes32 postingRef,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) internal returns (uint256 commitmentId) {
        return _executeCommitmentActivationWithFee(
            creator,
            orgId,
            stake,
            feeTier,
            _commitmentActivateFee(stake, feeTier),
            postingRef,
            keyNonce,
            expiry,
            signature
        );
    }

    function _executeCommitmentActivationWithFee(
        address creator,
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        uint256 expectedFeeAmount,
        bytes32 postingRef,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) internal returns (uint256 commitmentId) {
        vm.prank(creator);
        return commitmentFunds.activateCommitment(
            address(responseCommitment),
            orgId,
            stake,
            expectedFeeAmount,
            feeRecipient,
            abi.encode(feeTier, postingRef, keyNonce, expiry, signature)
        );
    }

    function _commitmentActivateFee(uint256 stake, uint8 feeTier) internal view returns (uint256 fee) {
        FeeTier memory tier = responseCommitment.feeTier(responseCommitment.currentConfigVersion(), feeTier);
        return tier.baseFee + ((stake * tier.feeBps) / 10_000);
    }

    // ============ Application Helpers ============

    /// @notice Generate a unique applicationId
    function _generateApplicationId(address applicantAddr) internal returns (bytes32) {
        applicationNonce++;
        return keccak256(abi.encodePacked("app", applicantAddr, applicationNonce));
    }

    function _submitApplication(address applicantAddr) internal returns (bytes32 applicationId) {
        return _submitApplicationWithParams(applicantAddr, DEFAULT_RESPONSE_DEADLINE_DAYS);
    }

    /// @notice Submit an application with a custom response deadline.
    function _submitApplicationWithParams(address applicantAddr, uint8 responseDeadlineDays)
        internal
        returns (bytes32 applicationId)
    {
        applicationId = _generateApplicationId(applicantAddr);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signApplication(applicationId, applicantAddr, responseDeadlineDays, expiry);

        vm.prank(applicantAddr);
        responseCommitment.submitApplication(applicationId, responseDeadlineDays, expiry, signature);
    }

    // ============ Signature Helpers ============

    /// @notice Sign an application with the operator's private key
    function _signApplication(bytes32 applicationId, address applicantAddr, uint8 responseDeadlineDays, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash =
            keccak256(abi.encode(APPLICATION_TYPEHASH, applicationId, applicantAddr, responseDeadlineDays, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", responseCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Sign a commitment settle for the default employer with the operator's private key.
    function _signCommitmentSettlement(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        return _signCommitmentSettlement(
            commitmentId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            employer,
            keyNonce,
            expiry
        );
    }

    /// @notice Sign a commitment settle for a specific settler with the operator's private key.
    function _signCommitmentSettlement(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        address settler,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", responseCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Sign an expired settlement with the operator's private key.
    function _signExpiredCommitmentSettlement(
        uint256 commitmentId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", responseCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    /// @notice Sign a commitment creation with the operator's private key
    function _signCommitmentActivation(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        bytes32 postingRef,
        address creator,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                COMMITMENT_ACTIVATION_TYPEHASH,
                orgId,
                stake,
                feeTier,
                postingRef,
                creator,
                responseCommitment.currentConfigVersion(),
                keyNonce,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", responseCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Sign a commitment stop with the operator's private key.
    function _signCommitmentStop(uint256 commitmentId, address stopper, uint256 keyNonce, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(COMMITMENT_STOP_TYPEHASH, commitmentId, stopper, keyNonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", responseCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _forwardAs(address signer, address target, bytes memory callData) internal returns (bytes memory result) {
        vm.prank(address(forwarder));
        (bool success, bytes memory returned) = target.call(bytes.concat(callData, bytes20(signer)));

        if (!success) {
            assembly {
                revert(add(returned, 32), mload(returned))
            }
        }

        return returned;
    }

    // ============ Response Helpers ============

    /// @notice Generate a unique response ID
    function _generateResponseId(bytes32 applicationId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("response", applicationId, block.timestamp));
    }

    /// @notice Record an application response with the default executor
    function _respondToApplication(bytes32 applicationId) internal {
        _respondToApplicationAs(applicationId, executor);
    }

    /// @notice Record an application response as a specific executor
    function _respondToApplicationAs(bytes32 applicationId, address executor) internal {
        bytes32 responseId = _generateResponseId(applicationId);
        vm.prank(executor);
        responseCommitment.recordApplicationResponse(applicationId, responseId);
    }

    /// @notice Record an application response after warping past deadline
    function _respondToApplicationLate(bytes32 applicationId) internal {
        ApplicationView memory app = responseCommitment.application(applicationId);
        vm.warp(app.responseDeadline + 1);
        _respondToApplication(applicationId);
    }

    /// @notice Record multiple application responses
    function _batchRespondToApplications(bytes32[] memory applicationIds) internal {
        _batchRespondToApplicationsAs(applicationIds, executor);
    }

    /// @notice Record multiple application responses as a specific executor
    function _batchRespondToApplicationsAs(bytes32[] memory applicationIds, address executor) internal {
        bytes32[] memory responseIds = new bytes32[](applicationIds.length);
        for (uint256 i = 0; i < applicationIds.length; i++) {
            responseIds[i] = _generateResponseId(applicationIds[i]);
        }

        vm.prank(executor);
        responseCommitment.recordApplicationResponses(applicationIds, responseIds);
    }

    // ============ Commitment Lifecycle Helpers ============

    /// @notice Stop a commitment.
    function _stopCommitment(uint256 commitmentId) internal {
        _stopCommitmentAs(commitmentId, employer);
    }

    /// @notice Stop a commitment as a specific caller.
    function _stopCommitmentAs(uint256 commitmentId, address stopper) internal {
        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(commitmentId, stopper, keyNonce, expiry);
        vm.prank(stopper);
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    /// @notice Settle a commitment with zero counters.
    function _settleCommitment(uint256 commitmentId) internal {
        _settleCommitment(commitmentId, 0, 0, 0);
    }

    /// @notice Settle a commitment with operator-attested counters.
    function _settleCommitment(uint256 commitmentId, uint32 total, uint32 responded, uint32 onTime) internal {
        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        // Read the current time after helpers that may have warped the test clock.
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(total);
        bytes memory signature =
            _signCommitmentSettlement(commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry);
        vm.prank(employer);
        responseCommitment.settleCommitment(
            commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry, signature
        );
    }

    /// @notice Settle an expired commitment with zero counters.
    function _settleExpiredCommitment(uint256 commitmentId) internal {
        _settleExpiredCommitment(commitmentId, 0, 0, 0);
    }

    /// @notice Settle an expired commitment with operator-attested counters.
    function _settleExpiredCommitment(uint256 commitmentId, uint32 total, uint32 responded, uint32 onTime) internal {
        _settleExpiredCommitmentAs(commitmentId, total, responded, onTime, _counterSnapshotRoot(total), executor);
    }

    /// @notice Settle an expired commitment as a specific caller.
    function _settleExpiredCommitmentAs(
        uint256 commitmentId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot,
        address caller
    ) internal {
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(commitmentId, total, responded, onTime, counterSnapshotRoot);

        vm.prank(caller);
        responseCommitment.settleExpiredCommitment(
            commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry, signature
        );
    }

    function _expiredSettlementAuthorization(
        uint256 commitmentId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot
    ) internal returns (uint256 keyNonce, uint256 expiry, bytes memory signature) {
        keyNonce = _nextExpiredSettlementKeyNonce();
        expiry = vm.getBlockTimestamp() + 1 hours;
        signature = _signExpiredCommitmentSettlement(
            commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry
        );
    }

    function _expectExpiredSettlementRevert(
        bytes memory expectedRevert,
        uint256 commitmentId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot,
        address caller
    ) internal {
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(commitmentId, total, responded, onTime, counterSnapshotRoot);

        vm.prank(caller);
        vm.expectRevert(expectedRevert);
        responseCommitment.settleExpiredCommitment(
            commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry, signature
        );
    }

    /// @notice Build a deterministic non-zero counter root when test counters include applications.
    function _counterSnapshotRoot(uint32 totalApplications) internal pure returns (bytes32) {
        if (totalApplications == 0) return bytes32(0);

        return keccak256(abi.encode("test-counter-snapshot-root", totalApplications));
    }

    function _expiredStoppedCommitment() internal returns (uint256 commitmentId) {
        commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        _warpToExpiration(commitmentId);
    }

    // ============ Time Helpers ============

    /// @notice Warp to commitment expiration time
    function _warpToExpiration(uint256 commitmentId) internal {
        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        vm.warp(commitment.stoppedAt + TEST_MAX_STOPPED_DURATION + 1);
    }

    /// @notice Warp past application response deadline
    function _warpPastDeadline(bytes32 applicationId) internal {
        ApplicationView memory app = responseCommitment.application(applicationId);
        vm.warp(app.responseDeadline + 1);
    }

    // ============ Assertion Helpers ============

    /// @notice Assert commitment status
    function _assertCommitmentStatus(uint256 commitmentId, CommitmentStatus expectedStatus) internal view {
        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(uint8(commitment.status), uint8(expectedStatus), "Unexpected commitment status");
    }

    /// @notice Assert application responded
    function _assertApplicationResponded(bytes32 applicationId) internal view {
        ApplicationView memory app = responseCommitment.application(applicationId);
        assertTrue(app.isResponded, "Application should be responded");
    }

    /// @notice Get org available balance
    function _getOrgAvailableBalance(uint256 orgId) internal view returns (uint256) {
        return commitmentFunds.availableBalance(orgId);
    }

    /// @notice Get org operational balance (total, including locked)
    function _getOrgOperationalBalance(uint256 orgId) internal view returns (uint256) {
        OrgCommitmentBalance memory balance = commitmentFunds.commitmentBalance(orgId);

        return uint256(balance.available) + uint256(balance.lockedInCommitments);
    }

    /// @notice Derive a packed keyNonce from a scoped one-shot key and nonce zero.
    function _packKeyNonce(uint16 scope, uint256 randomKey) internal pure returns (uint256) {
        require(randomKey <= type(uint176).max, "random key too large");

        return (uint256(scope) << 240) | (randomKey << 64);
    }

    /// @notice Safely narrow a value to uint32 in tests.
    function _toUint32(uint256 value) internal pure returns (uint32) {
        return SafeCast.toUint32(value);
    }

    /// @notice Safely narrow a value to uint96 in tests.
    function _toUint96(uint256 value) internal pure returns (uint96) {
        return SafeCast.toUint96(value);
    }

    /// @notice Extract the NoncesKeyed authorization key from a packed keyNonce.
    function _authorizationKeyFromKeyNonce(uint256 keyNonce) internal pure returns (uint192) {
        return SafeCast.toUint192(keyNonce >> 64);
    }

    /// @notice Allocate the next commitment-creation keyNonce.
    function _nextCommitmentActivationKeyNonce() internal returns (uint256) {
        creationNonce++;

        return _packKeyNonce(NONCE_SCOPE_COMMITMENT_ACTIVATION, creationNonce);
    }

    /// @notice Allocate the next commitment-settle keyNonce.
    function _nextCommitmentSettleKeyNonce() internal returns (uint256) {
        settleNonce++;

        return _packKeyNonce(NONCE_SCOPE_COMMITMENT_SETTLEMENT, settleNonce);
    }

    /// @notice Allocate the next expired-settlement keyNonce.
    function _nextExpiredSettlementKeyNonce() internal returns (uint256) {
        expiredSettlementNonce++;

        return _packKeyNonce(NONCE_SCOPE_EXPIRED_COMMITMENT_SETTLEMENT, expiredSettlementNonce);
    }

    /// @notice Allocate the next commitment-stop keyNonce.
    function _nextCommitmentStopKeyNonce() internal returns (uint256) {
        stopNonce++;

        return _packKeyNonce(NONCE_SCOPE_COMMITMENT_STOP, stopNonce);
    }

    /// @notice Allocate a domain-verification keyNonce with deterministic test entropy.
    function _nextDomainVerificationKeyNonce(uint256 salt) internal returns (uint256) {
        domainVerificationNonce++;

        return _packKeyNonce(NONCE_SCOPE_DOMAIN_VERIFICATION, domainVerificationNonce + salt);
    }
}
