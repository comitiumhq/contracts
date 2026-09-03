// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {JobCommitment} from "../../src/JobCommitment.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {JobFunds} from "../../src/JobFunds.sol";
import {IJobCommitment, ApplicationView} from "../../src/interfaces/IJobCommitment.sol";
import {IJobFunds} from "../../src/interfaces/IJobFunds.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";
import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";
import {USDC} from "../mocks/USDC.sol";
import {JobCommitmentTestBase, TEST_APPLICANT_STAKE} from "../shared/TestBase.sol";

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

contract ReentrantJobCommitmentCaller {
    IJobCommitment private immutable _jobCommitment;
    IJobFunds private immutable _jobFunds;
    IERC20 private immutable _stakeToken;
    address private immutable _feeRecipient;

    bytes32 private _applicationId;
    uint256 private _orgId;
    uint256 private _jobId;
    uint256 private _jobStake;
    uint256 private _jobFee;
    uint8 private _feeTier;
    string private _contentURI;
    uint96 private _applicantStake;
    uint8 private _responseDeadlineDays;
    uint32 private _totalApplications;
    uint32 private _respondedApplications;
    uint32 private _onTimeResponses;
    bytes32 private _counterSnapshotRoot;
    uint256 private _keyNonce;
    uint256 private _expiry;
    bytes private _signature;

    constructor(IJobCommitment jobCommitment_, IJobFunds jobFunds_, IERC20 stakeToken_, address feeRecipient_) {
        _jobCommitment = jobCommitment_;
        _jobFunds = jobFunds_;
        _stakeToken = stakeToken_;
        _feeRecipient = feeRecipient_;
        _stakeToken.approve(address(_jobCommitment), type(uint256).max);
    }

    function configureSubmit(
        bytes32 applicationId_,
        uint96 applicantStake_,
        uint8 responseDeadlineDays_,
        uint256 expiry_,
        bytes calldata signature_
    ) external {
        _applicationId = applicationId_;
        _applicantStake = applicantStake_;
        _responseDeadlineDays = responseDeadlineDays_;
        _expiry = expiry_;
        _signature = signature_;
    }

    function configureCreate(
        uint256 orgId_,
        uint256 stake_,
        uint8 feeTier_,
        uint256 fee_,
        string calldata contentURI_,
        uint256 keyNonce_,
        uint256 expiry_,
        bytes calldata signature_
    ) external {
        _orgId = orgId_;
        _jobStake = stake_;
        _jobFee = fee_;
        _feeTier = feeTier_;
        _contentURI = contentURI_;
        _keyNonce = keyNonce_;
        _expiry = expiry_;
        _signature = signature_;
    }

    function configureClose(
        uint256 jobId_,
        uint32 totalApplications_,
        uint32 respondedApplications_,
        uint32 onTimeResponses_,
        bytes32 counterSnapshotRoot_,
        uint256 keyNonce_,
        uint256 expiry_,
        bytes calldata signature_
    ) external {
        _jobId = jobId_;
        _totalApplications = totalApplications_;
        _respondedApplications = respondedApplications_;
        _onTimeResponses = onTimeResponses_;
        _counterSnapshotRoot = counterSnapshotRoot_;
        _keyNonce = keyNonce_;
        _expiry = expiry_;
        _signature = signature_;
    }

    function configureExpiredSettlement(
        uint256 jobId_,
        uint32 totalApplications_,
        uint32 respondedApplications_,
        uint32 onTimeResponses_,
        bytes32 counterSnapshotRoot_
    ) external {
        _jobId = jobId_;
        _totalApplications = totalApplications_;
        _respondedApplications = respondedApplications_;
        _onTimeResponses = onTimeResponses_;
        _counterSnapshotRoot = counterSnapshotRoot_;
    }

    function configureWithdraw(bytes32 applicationId_) external {
        _applicationId = applicationId_;
    }

    function publishJob() external {
        bytes memory signature = _signature;
        _jobFunds.publishJob(
            address(_jobCommitment),
            _orgId,
            _jobStake,
            _jobFee,
            _feeRecipient,
            abi.encode(_feeTier, _contentURI, _keyNonce, _expiry, signature)
        );
    }

    function submitApplication() external {
        bytes memory signature = _signature;
        _jobCommitment.submitApplication(_applicationId, _applicantStake, _responseDeadlineDays, _expiry, signature);
    }

    function closeJob() external {
        bytes memory signature = _signature;
        _jobCommitment.closeJob(
            _jobId,
            _totalApplications,
            _respondedApplications,
            _onTimeResponses,
            _counterSnapshotRoot,
            _keyNonce,
            _expiry,
            signature
        );
    }

    function withdrawStake() external {
        _jobCommitment.withdrawStake(_applicationId);
    }

    function settleExpiredJob() external {
        _jobCommitment.settleExpiredJob(
            _jobId,
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
/// @notice Tests real malicious-token reentry attempts against JobCommitment token-transfer paths.
contract ReentrancyTest is JobCommitmentTestBase {
    function setUp() public override {
        operator = vm.addr(operatorPrivateKey);
        executor = vm.addr(executorPrivateKey);
        employer = vm.addr(employerPrivateKey);
        vm.label(employer, "employer");
        usdc = new ReentrantUSDC();
        forwarder = new ERC2771Forwarder("ComitiumForwarder");

        orgRegistry = new OrgRegistry(owner, address(forwarder), operator);
        jobFunds = new JobFunds(
            IERC20(address(usdc)), IOrgRegistry(address(orgRegistry)), feeRecipient, owner, address(forwarder)
        );
        jobCommitment = new JobCommitment(
            IERC20(address(usdc)),
            jobFunds,
            owner,
            address(forwarder),
            operator,
            executor,
            _defaultJobConfig(),
            _defaultFeeTiers(),
            TEST_APPLICANT_STAKE
        );

        uint32 commitmentVersion = jobCommitment.commitmentVersion();
        vm.prank(owner);
        jobFunds.registerJobCommitment(address(jobCommitment), commitmentVersion);

        vm.prank(owner);
        jobFunds.setCurrentJobCommitment(address(jobCommitment));

        _createOrgForEmployer(employer, "test.com", DEFAULT_ORG_ID);

        _fundAndDepositWithAuthorization(
            jobFunds, address(usdc), employerPrivateKey, DEFAULT_ORG_ID, ORG_OPERATIONAL_BALANCE
        );

        _fundApplicant(applicant1);
        _fundApplicant(applicant2);
    }

    function test_reentrancy_submitApplication_blocksNestedApplication() public {
        _publishJob(0);

        ReentrantJobCommitmentCaller attacker = _deployAttacker();
        bytes32 attackerApplicationId = _configureAttackerSubmit(attacker);
        bytes32 outerApplicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signApplication(
            outerApplicationId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry
        );

        _maliciousToken()
            .setAttack(
                address(attacker), false, true, abi.encodeCall(ReentrantJobCommitmentCaller.submitApplication, ())
            );

        vm.prank(applicant1);
        jobCommitment.submitApplication(
            outerApplicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature
        );

        assertTrue(jobCommitment.isApplicationIdUsed(outerApplicationId));
        assertFalse(jobCommitment.isApplicationIdUsed(attackerApplicationId));
        assertFalse(_maliciousToken().lastAttackSucceeded());
        assertEq(_maliciousToken().lastAttackRevertData(), _reentrancyGuardRevert());
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE);
        assertEq(usdc.balanceOf(address(jobCommitment)), APPLICANT_STAKE);
        assertEq(usdc.balanceOf(address(attacker)), APPLICANT_STAKE);
    }

    function test_reentrancy_publishJob_blocksNestedCreate() public {
        ReentrantJobCommitmentCaller attacker = _deployAttacker();
        _configureAttackerCreate(attacker);
        uint256 nextJobIdBefore = jobCommitment.nextJobId();
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmOuter", employer, keyNonce, expiry);

        _maliciousToken()
            .setAttack(address(attacker), true, false, abi.encodeCall(ReentrantJobCommitmentCaller.publishJob, ()));

        uint256 jobId =
            _executeJobPublish(employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmOuter", keyNonce, expiry, signature);

        assertEq(jobId, nextJobIdBefore);
        assertEq(jobCommitment.nextJobId(), nextJobIdBefore + 1);
        assertFalse(_maliciousToken().lastAttackSucceeded());
        assertEq(_maliciousToken().lastAttackRevertData(), _reentrancyGuardRevert());
    }

    function test_reentrancy_closeJob_blocksNestedClose() public {
        uint256 outerJobId = _publishJob(0);
        bytes32 appId = _applyToJob(outerJobId, applicant1);
        _respondToApplicationLate(appId);

        uint256 nestedJobId = _publishJob(0);
        _unpublishJob(outerJobId);
        _unpublishJob(nestedJobId);
        ReentrantJobCommitmentCaller attacker = _deployAttacker();
        _configureAttackerClose(attacker, nestedJobId);

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(1);
        bytes memory signature = _signJobClose(outerJobId, 1, 1, 0, counterSnapshotRoot, keyNonce, expiry);

        _maliciousToken()
            .setAttack(address(attacker), true, false, abi.encodeCall(ReentrantJobCommitmentCaller.closeJob, ()));

        vm.prank(employer);
        jobCommitment.closeJob(outerJobId, 1, 1, 0, counterSnapshotRoot, keyNonce, expiry, signature);

        _assertJobStatus(outerJobId, JobStatus.Closed);
        _assertJobStatus(nestedJobId, JobStatus.Unpublished);
        assertFalse(_maliciousToken().lastAttackSucceeded());
        assertEq(_maliciousToken().lastAttackRevertData(), _reentrancyGuardRevert());
    }

    function test_reentrancy_withdrawStake_blocksNestedWithdrawal() public {
        _publishJob(0);

        bytes32 outerApplicationId = _applyToJob(applicant1);
        ReentrantJobCommitmentCaller attacker = _deployAttacker();
        bytes32 attackerApplicationId = _submitApplicationFromAttacker(attacker);

        _respondToApplication(outerApplicationId);
        _respondToApplication(attackerApplicationId);

        uint256 applicantBalanceBefore = usdc.balanceOf(applicant1);
        uint256 attackerBalanceBefore = usdc.balanceOf(address(attacker));
        attacker.configureWithdraw(attackerApplicationId);
        _maliciousToken()
            .setAttack(address(attacker), true, false, abi.encodeCall(ReentrantJobCommitmentCaller.withdrawStake, ()));

        vm.prank(applicant1);
        jobCommitment.withdrawStake(outerApplicationId);

        ApplicationView memory outerApplication = jobCommitment.application(outerApplicationId);
        ApplicationView memory attackerApplication = jobCommitment.application(attackerApplicationId);
        assertTrue(outerApplication.stakeWithdrawn);
        assertFalse(attackerApplication.stakeWithdrawn);
        assertFalse(_maliciousToken().lastAttackSucceeded());
        assertEq(_maliciousToken().lastAttackRevertData(), _reentrancyGuardRevert());
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE);
        assertEq(usdc.balanceOf(applicant1), applicantBalanceBefore + APPLICANT_STAKE);
        assertEq(usdc.balanceOf(address(attacker)), attackerBalanceBefore);
        assertEq(usdc.balanceOf(address(jobCommitment)), APPLICANT_STAKE);
    }

    function test_reentrancy_rescueTokens_blocksNestedWithdrawal() public {
        _publishJob(0);

        ReentrantJobCommitmentCaller attacker = _deployAttacker();
        bytes32 attackerApplicationId = _submitApplicationFromAttacker(attacker);
        _respondToApplication(attackerApplicationId);

        usdc.mint(address(jobCommitment), APPLICANT_STAKE);
        attacker.configureWithdraw(attackerApplicationId);
        _maliciousToken()
            .setAttack(address(attacker), true, false, abi.encodeCall(ReentrantJobCommitmentCaller.withdrawStake, ()));

        uint256 ownerBalanceBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        jobCommitment.rescueTokens(address(usdc), owner, APPLICANT_STAKE);

        ApplicationView memory attackerApplication = jobCommitment.application(attackerApplicationId);
        assertFalse(attackerApplication.stakeWithdrawn);
        assertFalse(_maliciousToken().lastAttackSucceeded());
        assertEq(_maliciousToken().lastAttackRevertData(), _reentrancyGuardRevert());
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE);
        assertEq(usdc.balanceOf(owner), ownerBalanceBefore + APPLICANT_STAKE);
        assertEq(usdc.balanceOf(address(jobCommitment)), APPLICANT_STAKE);
    }

    function test_reentrancy_settleExpiredJob_blocksNestedSettle() public {
        uint256 outerJobId = _publishJob(0);
        _applyToJob(outerJobId, applicant1);
        _unpublishJob(outerJobId);
        _warpToExpiration(outerJobId);

        uint256 nestedJobId = _publishJob(0);
        ReentrantJobCommitmentCaller attacker = _deployAttacker();
        attacker.configureExpiredSettlement(nestedJobId, 0, 0, 0, _counterSnapshotRoot(0));

        _maliciousToken()
            .setAttack(
                address(attacker), true, false, abi.encodeCall(ReentrantJobCommitmentCaller.settleExpiredJob, ())
            );

        _settleExpiredJob(outerJobId, 1, 0, 0);

        _assertJobStatus(outerJobId, JobStatus.Closed);
        _assertJobStatus(nestedJobId, JobStatus.Published);
        assertFalse(_maliciousToken().lastAttackSucceeded());
        assertEq(_maliciousToken().lastAttackRevertData(), _reentrancyGuardRevert());
    }

    function _deployAttacker() private returns (ReentrantJobCommitmentCaller attacker) {
        attacker = new ReentrantJobCommitmentCaller(
            IJobCommitment(address(jobCommitment)), IJobFunds(address(jobFunds)), IERC20(address(usdc)), feeRecipient
        );
        usdc.mint(address(attacker), APPLICANT_STAKE);
    }

    function _configureAttackerSubmit(ReentrantJobCommitmentCaller attacker) private returns (bytes32 applicationId) {
        applicationId = _generateApplicationId(address(attacker));
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signApplication(
            applicationId, address(attacker), APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry
        );

        attacker.configureSubmit(applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature);
    }

    function _configureAttackerCreate(ReentrantJobCommitmentCaller attacker) private {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmNested", address(attacker), keyNonce, expiry);

        attacker.configureCreate(
            DEFAULT_ORG_ID,
            EMPLOYER_STAKE,
            0,
            _jobPublishFee(EMPLOYER_STAKE, 0),
            "QmNested",
            keyNonce,
            expiry,
            signature
        );
    }

    function _configureAttackerClose(ReentrantJobCommitmentCaller attacker, uint256 jobId) private {
        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(0);
        bytes memory signature = _signJobClose(jobId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry);

        attacker.configureClose(jobId, 0, 0, 0, counterSnapshotRoot, keyNonce, expiry, signature);
    }

    function _submitApplicationFromAttacker(ReentrantJobCommitmentCaller attacker)
        private
        returns (bytes32 applicationId)
    {
        applicationId = _configureAttackerSubmit(attacker);
        attacker.submitApplication();
    }

    function _maliciousToken() private view returns (ReentrantUSDC) {
        return ReentrantUSDC(address(usdc));
    }

    function _reentrancyGuardRevert() private pure returns (bytes memory) {
        return abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
    }
}
