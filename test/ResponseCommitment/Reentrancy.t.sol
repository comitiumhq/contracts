// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {ResponseCommitment} from "../../src/ResponseCommitment.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {CommitmentFunds} from "../../src/CommitmentFunds.sol";
import {IResponseCommitment} from "../../src/interfaces/IResponseCommitment.sol";
import {ICommitmentFunds} from "../../src/interfaces/ICommitmentFunds.sol";
import {CommitmentStatus} from "../../src/types/CommitmentTypes.sol";
import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";
import {USDC} from "../mocks/USDC.sol";
import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";

contract ReentrantUSDC is USDC {
    address public target;
    bytes public attackCalldata;
    bool public attackOnTransfer;
    bool public attackOnTransferFrom;
    bool public lastAttackSucceeded;
    bytes public lastAttackRevertData;
    bool private _entered;

    function setAttack(
        address target_,
        bool attackOnTransfer_,
        bool attackOnTransferFrom_,
        bytes calldata attackCalldata_
    ) external {
        target = target_;
        attackOnTransfer = attackOnTransfer_;
        attackOnTransferFrom = attackOnTransferFrom_;
        attackCalldata = attackCalldata_;
        lastAttackSucceeded = false;
        lastAttackRevertData = "";
        _entered = false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _maybeAttack(attackOnTransfer);

        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _maybeAttack(attackOnTransferFrom);

        return super.transferFrom(from, to, amount);
    }

    function _maybeAttack(bool enabled) private {
        if (!enabled || _entered || target == address(0)) return;

        _entered = true;
        (bool success, bytes memory revertData) = target.call(attackCalldata);
        lastAttackSucceeded = success;
        lastAttackRevertData = revertData;
        _entered = false;
    }
}

contract ReentrantResponseCommitmentCaller {
    IResponseCommitment private immutable _responseCommitment;
    ICommitmentFunds private immutable _commitmentFunds;
    address private immutable _feeRecipient;

    uint256 private _orgId;
    uint256 private _commitmentId;
    uint256 private _commitmentStake;
    uint256 private _commitmentFee;
    uint8 private _feeTier;
    bytes32 private _postingRef;
    uint32 private _totalApplications;
    uint32 private _respondedApplications;
    uint32 private _onTimeResponses;
    bytes32 private _counterSnapshotRoot;
    uint256 private _keyNonce;
    uint256 private _expiry;
    bytes private _signature;

    constructor(IResponseCommitment responseCommitment_, ICommitmentFunds commitmentFunds_, address feeRecipient_) {
        _responseCommitment = responseCommitment_;
        _commitmentFunds = commitmentFunds_;
        _feeRecipient = feeRecipient_;
    }

    function configureCreate(
        uint256 orgId_,
        uint256 stake_,
        uint8 feeTier_,
        uint256 fee_,
        bytes32 postingRef_,
        uint256 keyNonce_,
        uint256 expiry_,
        bytes calldata signature_
    ) external {
        _orgId = orgId_;
        _commitmentStake = stake_;
        _commitmentFee = fee_;
        _feeTier = feeTier_;
        _postingRef = postingRef_;
        _keyNonce = keyNonce_;
        _expiry = expiry_;
        _signature = signature_;
    }

    function configureSettle(
        uint256 commitmentId_,
        uint32 totalApplications_,
        uint32 respondedApplications_,
        uint32 onTimeResponses_,
        bytes32 counterSnapshotRoot_,
        uint256 keyNonce_,
        uint256 expiry_,
        bytes calldata signature_
    ) external {
        _commitmentId = commitmentId_;
        _totalApplications = totalApplications_;
        _respondedApplications = respondedApplications_;
        _onTimeResponses = onTimeResponses_;
        _counterSnapshotRoot = counterSnapshotRoot_;
        _keyNonce = keyNonce_;
        _expiry = expiry_;
        _signature = signature_;
    }

    function configureExpiredSettlement(
        uint256 commitmentId_,
        uint32 totalApplications_,
        uint32 respondedApplications_,
        uint32 onTimeResponses_,
        bytes32 counterSnapshotRoot_
    ) external {
        _commitmentId = commitmentId_;
        _totalApplications = totalApplications_;
        _respondedApplications = respondedApplications_;
        _onTimeResponses = onTimeResponses_;
        _counterSnapshotRoot = counterSnapshotRoot_;
    }

    function activateCommitment() external {
        bytes memory signature = _signature;
        _commitmentFunds.activateCommitment(
            address(_responseCommitment),
            _orgId,
            _commitmentStake,
            _commitmentFee,
            _feeRecipient,
            abi.encode(_feeTier, _postingRef, _keyNonce, _expiry, signature)
        );
    }

    function settleCommitment() external {
        bytes memory signature = _signature;
        _responseCommitment.settleCommitment(
            _commitmentId,
            _totalApplications,
            _respondedApplications,
            _onTimeResponses,
            _counterSnapshotRoot,
            _keyNonce,
            _expiry,
            signature
        );
    }

    function settleExpiredCommitment() external {
        _responseCommitment.settleExpiredCommitment(
            _commitmentId,
            _totalApplications,
            _respondedApplications,
            _onTimeResponses,
            _counterSnapshotRoot,
            0,
            block.timestamp,
            bytes("")
        );
    }
}

/// @title ReentrancyTest
/// @notice Tests real malicious-token reentry attempts against ResponseCommitment token-transfer paths.
contract ReentrancyTest is ResponseCommitmentTestBase {
    function setUp() public override {
        operator = vm.addr(operatorPrivateKey);
        executor = vm.addr(executorPrivateKey);
        employer = vm.addr(employerPrivateKey);
        vm.label(employer, "employer");
        usdc = new ReentrantUSDC();
        forwarder = new ERC2771Forwarder("ComitiumForwarder");

        orgRegistry = new OrgRegistry(owner, address(forwarder), operator);
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

    function test_reentrancy_activateCommitment_blocksNestedCreate() public {
        ReentrantResponseCommitmentCaller attacker = _deployAttacker();
        _configureAttackerCreate(attacker);
        uint256 nextCommitmentIdBefore = responseCommitment.nextCommitmentId();
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmOuter"), employer, keyNonce, expiry
        );

        _maliciousToken()
            .setAttack(
                address(attacker), true, false, abi.encodeCall(ReentrantResponseCommitmentCaller.activateCommitment, ())
            );

        uint256 commitmentId = _executeCommitmentActivation(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmOuter"), keyNonce, expiry, signature
        );

        assertEq(commitmentId, nextCommitmentIdBefore);
        assertEq(responseCommitment.nextCommitmentId(), nextCommitmentIdBefore + 1);
        assertFalse(_maliciousToken().lastAttackSucceeded());
        assertEq(_maliciousToken().lastAttackRevertData(), _reentrancyGuardRevert());
    }

    function test_reentrancy_settleCommitment_blocksNestedSettle() public {
        uint256 outerCommitmentId = _activateCommitment(0);
        uint256 nestedCommitmentId = _activateCommitment(0);
        _stopCommitment(outerCommitmentId);
        _stopCommitment(nestedCommitmentId);
        ReentrantResponseCommitmentCaller attacker = _deployAttacker();
        _configureAttackerSettle(attacker, nestedCommitmentId);

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(1);
        bytes memory signature =
            _signCommitmentSettlement(outerCommitmentId, 1, 1, 0, counterSnapshotRoot, keyNonce, expiry);

        _maliciousToken()
            .setAttack(
                address(attacker), true, false, abi.encodeCall(ReentrantResponseCommitmentCaller.settleCommitment, ())
            );

        vm.prank(employer);
        responseCommitment.settleCommitment(
            outerCommitmentId, 1, 1, 0, counterSnapshotRoot, keyNonce, expiry, signature
        );

        _assertCommitmentStatus(outerCommitmentId, CommitmentStatus.Settled);
        _assertCommitmentStatus(nestedCommitmentId, CommitmentStatus.Stopped);
        assertFalse(_maliciousToken().lastAttackSucceeded());
        assertEq(_maliciousToken().lastAttackRevertData(), _reentrancyGuardRevert());
    }

    function test_reentrancy_settleExpiredCommitment_blocksNestedSettle() public {
        uint256 outerCommitmentId = _activateCommitment(0);
        _stopCommitment(outerCommitmentId);
        _warpToExpiration(outerCommitmentId);

        uint256 nestedCommitmentId = _activateCommitment(0);
        ReentrantResponseCommitmentCaller attacker = _deployAttacker();
        attacker.configureExpiredSettlement(nestedCommitmentId, 0, 0, 0, _counterSnapshotRoot(0));

        _maliciousToken()
            .setAttack(
                address(attacker),
                true,
                false,
                abi.encodeCall(ReentrantResponseCommitmentCaller.settleExpiredCommitment, ())
            );

        _settleExpiredCommitment(outerCommitmentId, 1, 0, 0);

        _assertCommitmentStatus(outerCommitmentId, CommitmentStatus.Settled);
        _assertCommitmentStatus(nestedCommitmentId, CommitmentStatus.Active);
        assertFalse(_maliciousToken().lastAttackSucceeded());
        assertEq(_maliciousToken().lastAttackRevertData(), _reentrancyGuardRevert());
    }

    function _deployAttacker() private returns (ReentrantResponseCommitmentCaller attacker) {
        attacker = new ReentrantResponseCommitmentCaller(
            IResponseCommitment(address(responseCommitment)), ICommitmentFunds(address(commitmentFunds)), feeRecipient
        );
    }

    function _configureAttackerCreate(ReentrantResponseCommitmentCaller attacker) private {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmNested"), address(attacker), keyNonce, expiry
        );

        attacker.configureCreate(
            DEFAULT_ORG_ID,
            EMPLOYER_STAKE,
            0,
            _commitmentActivateFee(EMPLOYER_STAKE, 0),
            keccak256("QmNested"),
            keyNonce,
            expiry,
            signature
        );
    }

    function _configureAttackerSettle(ReentrantResponseCommitmentCaller attacker, uint256 commitmentId) private {
        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory signature = _signCommitmentSettlement(commitmentId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry);

        attacker.configureSettle(commitmentId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry, signature);
    }

    function _maliciousToken() private view returns (ReentrantUSDC) {
        return ReentrantUSDC(address(usdc));
    }

    function _reentrancyGuardRevert() private pure returns (bytes memory) {
        return abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
    }
}
