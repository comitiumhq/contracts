// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CommitmentActivation} from "../../src/abstract/CommitmentActivation.sol";
import {CommitmentApplication} from "../../src/abstract/CommitmentApplication.sol";
import {CommitmentLifecycle} from "../../src/abstract/CommitmentLifecycle.sol";
import {OperatorAuthorizer} from "../../src/abstract/OperatorAuthorizer.sol";
import {CommitmentAuthorizationLib} from "../../src/libraries/CommitmentAuthorizationLib.sol";
import {FeeTier, CommitmentConfig, SlashingTable} from "../../src/types/ConfigTypes.sol";
import {Commitment, Application} from "../../src/types/CommitmentTypes.sol";
import {CommitmentStatus} from "../../src/types/CommitmentTypes.sol";
import {ICommitmentFunds} from "../../src/interfaces/ICommitmentFunds.sol";
import {BASIS_POINTS} from "../../src/Constants.sol";

uint96 constant TEST_MIN_STAKE = 50_000_000;
uint96 constant TEST_TIER_0_BASE_FEE = 25_000_000;
uint96 constant TEST_TIER_1_BASE_FEE = 35_000_000;
uint96 constant TEST_TIER_2_BASE_FEE = 50_000_000;
uint32 constant TEST_MAX_STOPPED_DURATION = 90 days;
uint32 constant TEST_MAX_ACTIVE_DURATION = 365 days;
uint16 constant TEST_FEE_BPS_TIER_0 = 150;
uint16 constant TEST_FEE_BPS_TIER_1 = 250;
uint16 constant TEST_FEE_BPS_TIER_2 = 350;

function lifecycleHarnessOperator() pure returns (address operator) {
    return 0x6E9972213BF459853FA33E28Ab7219e9157C8d02;
}

// ============ Hevm cheatcodes ============

interface IHevm {
    function warp(uint256 newTimestamp) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external returns (address);
    function prank(address sender) external;
}

// ============ Mock ERC20 (minimal, SafeERC20 compatible) ============

contract MockERC20Echidna {
    mapping(address => uint256) public balanceOf;
    uint8 public constant decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}

// ============ Mock CommitmentFunds ============

contract MockCommitmentFundsEchidna {
    MockERC20Echidna public token;

    uint256 public availableBalance;
    uint256 public lockedInCommitments;
    uint256 public totalDeposited;
    mapping(uint256 => uint256) public commitmentStakeLocks;

    constructor(address token_) {
        token = MockERC20Echidna(token_);
    }

    function fundOrg(uint256 amount) external {
        availableBalance += amount;
        totalDeposited += amount;
    }

    function recordActiveCommitment(uint256 commitmentId, uint256 stakeAmount, uint256 feeAmount) external {
        uint256 totalCost = stakeAmount + feeAmount;
        require(availableBalance >= totalCost, "insufficient available balance");
        availableBalance -= totalCost;
        lockedInCommitments += stakeAmount;
        commitmentStakeLocks[commitmentId] = stakeAmount;
    }

    function settleCommitment(uint256, uint256 commitmentId, uint256 returnAmount) external {
        uint256 original = commitmentStakeLocks[commitmentId];
        require(original > 0, "commitment not locked");
        require(returnAmount <= original, "exceeds locked");
        delete commitmentStakeLocks[commitmentId];
        lockedInCommitments -= original;
        availableBalance += returnAmount;
    }
}

// ============ Main Harness ============

/// @title EchidnaCommitmentLifecycle
/// @notice Lifecycle harness for Medusa property and assertion tests.
/// @dev Inherits from real base contracts. Uses hevm.prank for msg.sender control
///      and external wrappers for calldata conversion.
contract EchidnaCommitmentLifecycle is CommitmentActivation, CommitmentApplication, CommitmentLifecycle {
    using SafeCast for uint256;

    IHevm constant hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Operator (known private key for EIP-712 signing)
    uint256 constant OPERATOR_PK = 0xBEEF;

    // Actor addresses must match the configured Medusa senders.
    address constant ORG_MEMBER = address(0x10000);
    address constant APPLICANT_A = address(0x20000);
    address constant APPLICANT_B = address(0x30000);

    // System
    MockERC20Echidna internal _token;
    MockCommitmentFundsEchidna internal _mockCommitmentFunds;
    address internal _operatorAddr;
    address internal _executorAddr;

    uint256 constant ORG_ID = 1;
    uint256 constant INITIAL_BALANCE = 1_000_000_000_000; // 1M USDC
    uint8 constant DEFAULT_DEADLINE_DAYS = 3;

    // Invariant tracking
    uint256[] public allCommitmentIds;
    mapping(uint256 => uint8) public prevStatus;

    // Model-only application-to-commitment links for settlement counters.
    mapping(uint256 => bytes32[]) public commitmentAppIds;
    mapping(uint256 => mapping(address => bool)) public hasApplied;
    mapping(uint256 => uint32) public commitmentTotalApps;
    mapping(uint256 => uint32) public commitmentRespondedApps;
    mapping(uint256 => uint32) public commitmentOnTimeResponses;

    uint256 public applicationNonce;
    uint256 public settleNonce;
    uint256 public expiredSettlementNonce;
    uint256 public creationNonce;
    uint256 public stopNonce;

    // ============ Constructor ============

    constructor() OperatorAuthorizer("EchidnaCommitmentLifecycle", "1", lifecycleHarnessOperator()) {
        _token = new MockERC20Echidna();
        _mockCommitmentFunds = new MockCommitmentFundsEchidna(address(_token));

        _operatorAddr = hevm.addr(OPERATOR_PK);
        _executorAddr = address(0xE0001);
        _addExecutor(_executorAddr);
        _configureDefaults();

        _token.mint(address(_mockCommitmentFunds), INITIAL_BALANCE);
        _mockCommitmentFunds.fundOrg(INITIAL_BALANCE);

        hevm.warp(1_700_000_000);
    }

    function _configureDefaults() internal {
        _currentConfigVersion = 1;
        _commitmentConfigs[1] = CommitmentConfig({
            minStake: TEST_MIN_STAKE,
            tierCount: 3,
            maxBatchSize: 50,
            maxStoppedDuration: TEST_MAX_STOPPED_DURATION,
            maxActiveDuration: TEST_MAX_ACTIVE_DURATION,
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
        _feeTiers[1][0] = FeeTier({baseFee: TEST_TIER_0_BASE_FEE, feeBps: TEST_FEE_BPS_TIER_0, deadlineDays: 3});
        _feeTiers[1][1] = FeeTier({baseFee: TEST_TIER_1_BASE_FEE, feeBps: TEST_FEE_BPS_TIER_1, deadlineDays: 7});
        _feeTiers[1][2] = FeeTier({baseFee: TEST_TIER_2_BASE_FEE, feeBps: TEST_FEE_BPS_TIER_2, deadlineDays: 14});
    }

    // ============ Virtual function overrides ============

    function _commitmentFunds() internal view override(CommitmentLifecycle) returns (ICommitmentFunds) {
        return ICommitmentFunds(address(_mockCommitmentFunds));
    }

    // ============ External wrappers (memory → calldata adapters) ============

    function ext_activateCommitment(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        uint256 expectedFee,
        bytes32 postingRef,
        uint256 nonce,
        uint256 expiry,
        bytes calldata sig
    ) external returns (uint256) {
        uint256 commitmentId = _activateCommitment(
            orgId, stake, feeTier, expectedFee, postingRef, msg.sender, nonce, expiry, sig
        );
        _mockCommitmentFunds.recordActiveCommitment(commitmentId, stake, expectedFee);
        return commitmentId;
    }

    function ext_stopCommitment(uint256 commitmentId, uint256 keyNonce, uint256 expiry, bytes calldata sig) external {
        _stopCommitment(commitmentId, keyNonce, expiry, sig);
    }

    function ext_submitApplication(
        bytes32 applicationId,
        uint8 responseDeadlineDays,
        uint256 expiry,
        bytes calldata sig
    ) external {
        _submitApplication(applicationId, responseDeadlineDays, expiry, sig, keccak256(msg.data));
    }

    function ext_recordApplicationResponse(bytes32 applicationId, bytes32 responseId) external {
        _recordApplicationResponse(applicationId, responseId);
    }

    function ext_settleCommitment(
        uint256 commitmentId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot,
        uint256 nonce,
        uint256 expiry,
        bytes calldata sig
    ) external {
        _settleCommitment(commitmentId, total, responded, onTime, counterSnapshotRoot, nonce, expiry, sig);
    }

    function ext_settleExpiredCommitment(
        uint256 commitmentId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry,
        bytes calldata sig
    ) external {
        _settleExpiredCommitment(commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry, sig);
    }

    // ============ Signature helpers ============

    function _makeApplicationSig(bytes32 applicationId, address applicant, uint8 responseDeadlineDays, uint256 expiry)
        internal
        returns (bytes memory)
    {
        bytes32 structHash =
            CommitmentAuthorizationLib.hashApplication(applicationId, applicant, responseDeadlineDays, expiry);
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(OPERATOR_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeSettleSig(
        uint256 commitmentId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot,
        address submitter,
        uint256 keyNonce,
        uint256 expiry
    ) internal returns (bytes memory) {
        bytes32 structHash = CommitmentAuthorizationLib.hashCommitmentSettlement(
            commitmentId, total, responded, onTime, counterSnapshotRoot, submitter, keyNonce, expiry
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(OPERATOR_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeExpiredSettlementSig(
        uint256 commitmentId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry
    ) internal returns (bytes memory) {
        bytes32 structHash = CommitmentAuthorizationLib.hashExpiredCommitmentSettlement(
            commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(OPERATOR_PK, digest);

        return abi.encodePacked(r, s, v);
    }

    function _counterSnapshotRoot(uint32 total) internal pure returns (bytes32) {
        if (total == 0) return bytes32(0);

        return keccak256(abi.encode("medusa-counter-snapshot-root", total));
    }

    function _makeCreationSig(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        bytes32 postingRef,
        address creator,
        uint256 keyNonce,
        uint256 expiry
    ) internal returns (bytes memory) {
        bytes32 structHash = CommitmentAuthorizationLib.hashCommitmentActivation(
            orgId, stake, feeTier, postingRef, creator, _currentConfigVersion, keyNonce, expiry
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(OPERATOR_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _makeStopSig(uint256 commitmentId, address stopper, uint256 keyNonce, uint256 expiry)
        internal
        returns (bytes memory)
    {
        bytes32 structHash = CommitmentAuthorizationLib.hashCommitmentStop(commitmentId, stopper, keyNonce, expiry);
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = hevm.sign(OPERATOR_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _packKeyNonce(uint16 scope, uint256 randomKey) internal pure returns (uint256) {
        require(randomKey <= type(uint176).max, "random key too large");

        return (uint256(scope) << 240) | (randomKey << 64);
    }

    function _nextCreationKeyNonce() internal returns (uint256) {
        creationNonce++;

        return _packKeyNonce(CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_ACTIVATION, creationNonce);
    }

    function _nextSettleKeyNonce() internal returns (uint256) {
        settleNonce++;

        return _packKeyNonce(CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_SETTLEMENT, settleNonce);
    }

    function _nextExpiredSettlementKeyNonce() internal returns (uint256) {
        expiredSettlementNonce++;

        return
            _packKeyNonce(CommitmentAuthorizationLib.NONCE_SCOPE_EXPIRED_COMMITMENT_SETTLEMENT, expiredSettlementNonce);
    }

    function _nextStopKeyNonce() internal returns (uint256) {
        stopNonce++;

        return _packKeyNonce(CommitmentAuthorizationLib.NONCE_SCOPE_COMMITMENT_STOP, stopNonce);
    }

    // ============ Lookup helpers ============

    function _clampCommitmentId(uint256 idx) internal view returns (uint256) {
        if (allCommitmentIds.length == 0) return 0;
        return allCommitmentIds[idx % allCommitmentIds.length];
    }

    function _findUnrespondedAppId(uint256 commitmentId) internal view returns (bytes32) {
        bytes32[] storage appIds = commitmentAppIds[commitmentId];
        for (uint256 i = 0; i < appIds.length; i++) {
            if (!_application(appIds[i]).isResponded) return appIds[i];
        }
        return bytes32(0);
    }

    // ============ Fuzz actions ============

    /// @notice Create a commitment (only ORG_MEMBER)
    function action_activateCommitment(uint256 stake, uint8 feeTier) public {
        if (msg.sender != ORG_MEMBER) return;

        stake = TEST_MIN_STAKE + (stake % (10_000_000_000 - TEST_MIN_STAKE + 1));
        feeTier = feeTier % 3;

        uint256 baseFee;
        uint256 feeBps;
        if (feeTier == 0) {
            baseFee = TEST_TIER_0_BASE_FEE;
            feeBps = TEST_FEE_BPS_TIER_0;
        } else if (feeTier == 1) {
            baseFee = TEST_TIER_1_BASE_FEE;
            feeBps = TEST_FEE_BPS_TIER_1;
        } else {
            baseFee = TEST_TIER_2_BASE_FEE;
            feeBps = TEST_FEE_BPS_TIER_2;
        }
        uint256 fee = baseFee + ((stake * feeBps) / BASIS_POINTS);
        uint256 totalCost = stake + fee;
        if (_mockCommitmentFunds.availableBalance() < totalCost) return;

        // Use prank + external wrapper to convert memory→calldata
        uint256 keyNonce = _nextCreationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 postingRef = keccak256("medusa-posting");
        bytes memory sig = _makeCreationSig(ORG_ID, stake, feeTier, postingRef, ORG_MEMBER, keyNonce, expiry);
        hevm.prank(ORG_MEMBER);
        uint256 commitmentId =
            this.ext_activateCommitment(ORG_ID, stake, feeTier, fee, postingRef, keyNonce, expiry, sig);

        allCommitmentIds.push(commitmentId);
        prevStatus[commitmentId] = uint8(CommitmentStatus.Active);

        Commitment storage commitment = _commitment(commitmentId);
        assert(uint256(commitment.stake) + uint256(commitment.feeAmount) == totalCost);

        _checkCommitmentInvariants(commitmentId);
        _checkSolvencyInvariant();
    }

    /// @notice Submit an application associated with a modeled commitment.
    function action_applyToCommitment(uint256 commitmentIdx) public {
        if (msg.sender == ORG_MEMBER) return;
        if (allCommitmentIds.length == 0) return;

        uint256 commitmentId = _clampCommitmentId(commitmentIdx);
        Commitment storage commitment = _commitment(commitmentId);
        if (commitment.status != CommitmentStatus.Active) return;
        if (hasApplied[commitmentId][msg.sender]) return;

        applicationNonce++;
        bytes32 applicationId = keccak256(abi.encodePacked("app", msg.sender, applicationNonce));
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _makeApplicationSig(applicationId, msg.sender, DEFAULT_DEADLINE_DAYS, expiry);

        address applicant = msg.sender;
        hevm.prank(applicant);
        this.ext_submitApplication(applicationId, DEFAULT_DEADLINE_DAYS, expiry, sig);

        commitmentAppIds[commitmentId].push(applicationId);
        hasApplied[commitmentId][applicant] = true;
        commitmentTotalApps[commitmentId]++;

        _checkCommitmentInvariants(commitmentId);
    }

    /// @notice Record an application response ON TIME (org member)
    function action_respondOnTime(uint256 commitmentIdx) public {
        if (msg.sender != ORG_MEMBER) return;
        if (allCommitmentIds.length == 0) return;

        uint256 commitmentId = _clampCommitmentId(commitmentIdx);
        Commitment storage commitment = _commitment(commitmentId);
        if (commitment.status == CommitmentStatus.Settled) return;

        bytes32 appId = _findUnrespondedAppId(commitmentId);
        if (appId == bytes32(0)) return;

        bytes32 responseId = keccak256(abi.encodePacked("ontime", appId));

        hevm.prank(_executorAddr);
        this.ext_recordApplicationResponse(appId, responseId);

        commitmentRespondedApps[commitmentId]++;
        Application storage app = _application(appId);
        if (app.respondedAt <= app.responseDeadline) commitmentOnTimeResponses[commitmentId]++;

        _checkCommitmentInvariants(commitmentId);
    }

    /// @notice Record an application response LATE (org member, past deadline)
    function action_respondLate(uint256 commitmentIdx) public {
        if (msg.sender != ORG_MEMBER) return;
        if (allCommitmentIds.length == 0) return;

        uint256 commitmentId = _clampCommitmentId(commitmentIdx);
        Commitment storage commitment = _commitment(commitmentId);
        if (commitment.status == CommitmentStatus.Settled) return;

        bytes32 appId = _findUnrespondedAppId(commitmentId);
        if (appId == bytes32(0)) return;

        Application storage app = _application(appId);

        if (block.timestamp <= app.responseDeadline) hevm.warp(uint256(app.responseDeadline) + 1);

        bytes32 responseId = keccak256(abi.encodePacked("late", appId));

        hevm.prank(_executorAddr);
        this.ext_recordApplicationResponse(appId, responseId);

        commitmentRespondedApps[commitmentId]++;
        // Late response — don't increment onTime

        _checkCommitmentInvariants(commitmentId);
    }

    /// @notice Stop a commitment.
    function action_stopCommitment(uint256 commitmentIdx) public {
        if (msg.sender != ORG_MEMBER) return;
        if (allCommitmentIds.length == 0) return;

        uint256 commitmentId = _clampCommitmentId(commitmentIdx);
        Commitment storage commitment = _commitment(commitmentId);
        if (commitment.status != CommitmentStatus.Active) return;

        uint256 keyNonce = _nextStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _makeStopSig(commitmentId, ORG_MEMBER, keyNonce, expiry);
        hevm.prank(ORG_MEMBER);
        this.ext_stopCommitment(commitmentId, keyNonce, expiry, sig);
        _checkCommitmentInvariants(commitmentId);
    }

    /// @notice Settle a commitment after all applications are responded.
    function action_settleCommitment(uint256 commitmentIdx) public {
        if (msg.sender != ORG_MEMBER) return;
        if (allCommitmentIds.length == 0) return;

        uint256 commitmentId = _clampCommitmentId(commitmentIdx);
        Commitment storage commitment = _commitment(commitmentId);
        if (commitment.status == CommitmentStatus.Settled) return;

        uint32 total = commitmentTotalApps[commitmentId];
        uint32 responded = commitmentRespondedApps[commitmentId];
        if (total > 0 && responded < total) return;

        uint32 onTime = commitmentOnTimeResponses[commitmentId];
        uint256 keyNonce = _nextSettleKeyNonce();
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(total);

        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig =
            _makeSettleSig(commitmentId, total, responded, onTime, counterSnapshotRoot, ORG_MEMBER, keyNonce, expiry);

        hevm.prank(ORG_MEMBER);
        this.ext_settleCommitment(commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry, sig);

        _checkCommitmentInvariants(commitmentId);
        _checkSolvencyInvariant();
    }

    /// @notice Settle an expired commitment after advancing the test clock.
    function action_settleExpiredCommitment(uint256 commitmentIdx) public {
        if (allCommitmentIds.length == 0) return;

        uint256 commitmentId = _clampCommitmentId(commitmentIdx);
        Commitment storage commitment = _commitment(commitmentId);
        if (commitment.status == CommitmentStatus.Settled) return;
        if (commitment.status == CommitmentStatus.Stopped) {
            hevm.warp(uint256(commitment.stoppedAt) + TEST_MAX_STOPPED_DURATION + 1);
        } else if (commitment.status == CommitmentStatus.Active) {
            hevm.warp(uint256(commitment.activatedAt) + TEST_MAX_ACTIVE_DURATION + 1);
        } else {
            return;
        }

        uint32 total = commitmentTotalApps[commitmentId];
        uint32 responded = commitmentRespondedApps[commitmentId];
        uint32 onTime = commitmentOnTimeResponses[commitmentId];

        bytes32 counterSnapshotRoot = _counterSnapshotRoot(total);
        uint256 keyNonce = _nextExpiredSettlementKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig =
            _makeExpiredSettlementSig(commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry);

        this.ext_settleExpiredCommitment(
            commitmentId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry, sig
        );
        _checkCommitmentInvariants(commitmentId);
        _checkSolvencyInvariant();
    }

    // ============ INVARIANT CHECKS ============

    function _checkCommitmentInvariants(uint256 commitmentId) internal {
        Commitment storage commitment = _commitment(commitmentId);
        if (commitment.creator == address(0)) return;

        // Commitment status never moves backward.
        uint8 currentStatus = uint8(commitment.status);
        assert(currentStatus >= prevStatus[commitmentId]);
        prevStatus[commitmentId] = currentStatus;
    }

    function _checkSolvencyInvariant() internal view {
        uint256 accounted = _mockCommitmentFunds.availableBalance() + _mockCommitmentFunds.lockedInCommitments();
        assert(_token.balanceOf(address(_mockCommitmentFunds)) >= accounted);
    }
}
