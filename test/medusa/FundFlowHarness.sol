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
import {BASIS_POINTS, SLASH_BURN_ADDRESS} from "../../src/Constants.sol";

uint96 constant TEST_MIN_STAKE = 50_000_000;
uint96 constant TEST_TIER_0_BASE_FEE = 25_000_000;
uint96 constant TEST_TIER_1_BASE_FEE = 35_000_000;
uint96 constant TEST_TIER_2_BASE_FEE = 50_000_000;
uint32 constant TEST_MAX_STOPPED_DURATION = 90 days;
uint32 constant TEST_MAX_ACTIVE_DURATION = 365 days;
uint16 constant TEST_FEE_BPS_TIER_0 = 150;
uint16 constant TEST_FEE_BPS_TIER_1 = 250;
uint16 constant TEST_FEE_BPS_TIER_2 = 350;

function fundFlowHarnessOperator() pure returns (address operator) {
    return 0x6E9972213BF459853FA33E28Ab7219e9157C8d02;
}

// ============ Hevm cheatcodes ============

interface IHevm {
    function warp(uint256 newTimestamp) external;
    function sign(uint256 privateKey, bytes32 digest) external returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external returns (address);
    function prank(address sender) external;
}

// ============ Mock ERC20 with totalSupply tracking ============

contract MockERC20FundFlow {
    mapping(address => uint256) public balanceOf;
    uint8 public constant decimals = 6;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
}

// ============ Mock CommitmentFunds with full accounting ============

contract MockCommitmentFundsFundFlow {
    MockERC20FundFlow public token;
    address public feeRecipient;

    uint256 public availableBalance;
    uint256 public lockedInCommitments;
    uint256 public totalDeposited;
    uint256 public totalReturned; // from commitment settles
    mapping(uint256 => uint256) public commitmentStakeLocks;

    constructor(address token_, address feeRecipient_) {
        token = MockERC20FundFlow(token_);
        feeRecipient = feeRecipient_;
    }

    // ============ Balance operations ============

    function depositCommitmentFunds(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        availableBalance += amount;
        totalDeposited += amount;
    }

    function withdrawCommitmentFunds(uint256 amount) external {
        require(amount <= availableBalance, "insufficient available");
        availableBalance -= amount;
        require(token.transfer(msg.sender, amount), "transfer failed");
    }

    // ============ ResponseCommitment integration ============

    function recordActiveCommitment(uint256 commitmentId, uint256 stakeAmount, uint256 feeAmount) external {
        uint256 totalCost = stakeAmount + feeAmount;
        require(availableBalance >= totalCost, "insufficient available balance");
        require(commitmentStakeLocks[commitmentId] == 0, "already locked");
        availableBalance -= totalCost;
        lockedInCommitments += stakeAmount;
        commitmentStakeLocks[commitmentId] = stakeAmount;
        if (feeAmount > 0) require(token.transfer(feeRecipient, feeAmount), "fee transfer failed");
    }

    function settleCommitment(uint256, uint256 commitmentId, uint256 returnAmount) external {
        uint256 original = commitmentStakeLocks[commitmentId];
        require(original > 0, "commitment not locked");
        require(returnAmount <= original, "exceeds locked");
        delete commitmentStakeLocks[commitmentId];
        lockedInCommitments -= original;
        availableBalance += returnAmount;
        uint256 slashed = original - returnAmount;
        if (slashed > 0) require(token.transfer(SLASH_BURN_ADDRESS, slashed), "slash transfer failed");
    }
}

// ============ Main Harness ============

/// @title EchidnaFundFlow
/// @notice Fund-flow harness for Medusa property and assertion tests.
/// @dev Inherits from real base contracts. Uses hevm.prank for msg.sender control
///      and external wrappers for calldata conversion.
contract EchidnaFundFlow is CommitmentActivation, CommitmentApplication, CommitmentLifecycle {
    using SafeCast for uint256;

    IHevm constant hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Operator (known private key for EIP-712 signing)
    uint256 constant OPERATOR_PK = 0xBEEF;

    // Actor addresses must match the configured Medusa senders.
    address constant ORG_MEMBER = address(0x10000);
    address constant APPLICANT_A = address(0x20000);
    address constant APPLICANT_B = address(0x30000);
    address constant FEE_RECIPIENT = address(0x40000);

    // System
    MockERC20FundFlow internal _token;
    MockCommitmentFundsFundFlow internal _mockCommitmentFunds;
    address internal _operatorAddr;
    address internal _executorAddr;

    uint256 constant ORG_ID = 1;
    uint256 constant ORG_INITIAL = 5_000_000_000_000;
    uint8 constant DEFAULT_DEADLINE_DAYS = 3;

    // Tracking
    uint256[] public allCommitmentIds;
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

    // Per-commitment stake tracking for solvency check
    mapping(uint256 => uint256) public employerStakeInCommitmentFunds;

    // ============ Constructor ============

    constructor() OperatorAuthorizer("EchidnaFundFlow", "1", fundFlowHarnessOperator()) {
        _token = new MockERC20FundFlow();
        _mockCommitmentFunds = new MockCommitmentFundsFundFlow(address(_token), FEE_RECIPIENT);

        _operatorAddr = hevm.addr(OPERATOR_PK);
        _executorAddr = address(0xE0001);
        _addExecutor(_executorAddr);
        _configureDefaults();

        _token.mint(ORG_MEMBER, ORG_INITIAL);

        hevm.prank(ORG_MEMBER);
        _mockCommitmentFunds.depositCommitmentFunds(ORG_INITIAL);

        assert(_token.totalSupply() == ORG_INITIAL);

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

    /// @notice Org member deposits into funding commitmentFunds
    function action_deposit(uint256 amount) public {
        if (msg.sender != ORG_MEMBER) return;
        amount = 1 + (amount % 1_000_000_000_000); // 1 to 1M USDC
        if (_token.balanceOf(ORG_MEMBER) < amount) return;

        hevm.prank(ORG_MEMBER);
        _mockCommitmentFunds.depositCommitmentFunds(amount);

        _checkGlobalConservation();
        _checkCommitmentFundsSolvency();
    }

    /// @notice Org member withdraws from funding commitmentFunds
    function action_withdrawCommitmentFunds(uint256 amount) public {
        if (msg.sender != ORG_MEMBER) return;
        amount = 1 + (amount % 1_000_000_000_000);

        uint256 available = _mockCommitmentFunds.availableBalance();
        if (amount > available) return;

        hevm.prank(ORG_MEMBER);
        _mockCommitmentFunds.withdrawCommitmentFunds(amount);

        _checkGlobalConservation();
        _checkCommitmentFundsSolvency();
    }

    /// @notice Create a commitment
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

        uint256 keyNonce = _nextCreationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 postingRef = keccak256("medusa-posting");
        bytes memory sig = _makeCreationSig(ORG_ID, stake, feeTier, postingRef, ORG_MEMBER, keyNonce, expiry);
        hevm.prank(ORG_MEMBER);
        uint256 commitmentId =
            this.ext_activateCommitment(ORG_ID, stake, feeTier, fee, postingRef, keyNonce, expiry, sig);

        allCommitmentIds.push(commitmentId);

        employerStakeInCommitmentFunds[commitmentId] = stake;

        _checkGlobalConservation();
        _checkNoApplicantFunds();
        _checkCommitmentFundsSolvency();
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

        _checkGlobalConservation();
        _checkNoApplicantFunds();
    }

    /// @notice Respond on time
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
    }

    /// @notice Respond late (past deadline)
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
        // Late — don't increment onTime
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

        employerStakeInCommitmentFunds[commitmentId] = 0;

        assert(_mockCommitmentFunds.commitmentStakeLocks(commitmentId) == 0);

        _checkMultiCommitmentNonContamination(commitmentId);

        _checkGlobalConservation();
        _checkNoApplicantFunds();
        _checkCommitmentFundsSolvency();
    }

    /// @notice Settle an expired commitment.
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

        employerStakeInCommitmentFunds[commitmentId] = 0;

        assert(_mockCommitmentFunds.commitmentStakeLocks(commitmentId) == 0);

        _checkGlobalConservation();
        _checkNoApplicantFunds();
        _checkCommitmentFundsSolvency();
    }

    // ============ INVARIANT CHECKS ============

    /// @notice Assert global USDC conservation.
    function _checkGlobalConservation() internal view {
        uint256 jcBalance = _token.balanceOf(address(this));
        uint256 commitmentFundsBalance = _token.balanceOf(address(_mockCommitmentFunds));
        uint256 feeRecipientBalance = _token.balanceOf(FEE_RECIPIENT);
        uint256 burnAddressBalance = _token.balanceOf(SLASH_BURN_ADDRESS);
        uint256 orgMemberBalance = _token.balanceOf(ORG_MEMBER);
        uint256 applicantABalance = _token.balanceOf(APPLICANT_A);
        uint256 applicantBBalance = _token.balanceOf(APPLICANT_B);

        uint256 total = jcBalance + commitmentFundsBalance + feeRecipientBalance + burnAddressBalance + orgMemberBalance
            + applicantABalance + applicantBBalance;

        assert(total == ORG_INITIAL);
    }

    /// @notice Applications never deposit funds into ResponseCommitment.
    function _checkNoApplicantFunds() internal view {
        assert(_token.balanceOf(address(this)) == 0);
    }

    /// @notice Assert that CommitmentFunds covers available and locked org funds.
    function _checkCommitmentFundsSolvency() internal view {
        uint256 commitmentFundsBalance = _token.balanceOf(address(_mockCommitmentFunds));
        uint256 accounted = _mockCommitmentFunds.availableBalance() + _mockCommitmentFunds.lockedInCommitments();

        assert(commitmentFundsBalance >= accounted);
    }

    /// @notice Assert that settling one commitment does not change other commitment stakes.
    function _checkMultiCommitmentNonContamination(uint256 completedCommitmentId) internal view {
        for (uint256 i = 0; i < allCommitmentIds.length; i++) {
            uint256 otherCommitmentId = allCommitmentIds[i];
            if (otherCommitmentId == completedCommitmentId) continue;

            Commitment storage otherCommitment = _commitment(otherCommitmentId);
            if (otherCommitment.status == CommitmentStatus.Settled) continue;

            if (employerStakeInCommitmentFunds[otherCommitmentId] > 0) {
                assert(uint256(otherCommitment.stake) == employerStakeInCommitmentFunds[otherCommitmentId]);
            }
        }
    }
}
