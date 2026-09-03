// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {JobCommitment} from "../../src/JobCommitment.sol";
import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {JobFunds} from "../../src/JobFunds.sol";
import {OrgJobBalance} from "../../src/interfaces/IJobFunds.sol";
import {JobView, ApplicationView} from "../../src/interfaces/IJobCommitment.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";

import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";

import {USDC} from "../mocks/USDC.sol";
import {Eip3009TestHelper} from "./Eip3009TestHelper.sol";
import {SLASH_BURN_ADDRESS as PROTOCOL_SLASH_BURN_ADDRESS} from "../../src/Constants.sol";
import {FeeTier, JobConfig, SlashingTable} from "../../src/types/ConfigTypes.sol";
import {JobAuthorizationLib} from "../../src/libraries/JobAuthorizationLib.sol";
import {OrgAuthorizationLib} from "../../src/libraries/OrgAuthorizationLib.sol";

// ============ Test Constants ============
// Default values matching constructor config — tests can't read storage configs easily in setup
uint256 constant TEST_MIN_STAKE = 50_000_000;
uint96 constant TEST_TIER_0_BASE_FEE = 25_000_000;
uint96 constant TEST_TIER_1_BASE_FEE = 35_000_000;
uint96 constant TEST_TIER_2_BASE_FEE = 50_000_000;
uint96 constant TEST_APPLICANT_STAKE = 3_000_000;
uint96 constant TEST_APPLICANT_STAKE_LOWER = 1_000_000;
uint96 constant TEST_APPLICANT_STAKE_UPPER = 10_000_000;
uint256 constant TEST_MAX_UNPUBLISHED_DURATION = 90 days;
uint256 constant TEST_MAX_PUBLISHED_DURATION = 365 days;
uint256 constant TEST_FEE_TIER_0 = 150;
uint256 constant TEST_FEE_TIER_1 = 250;
uint256 constant TEST_FEE_TIER_2 = 350;
uint8 constant TEST_DEADLINE_DAYS_TIER_0 = 3;
uint8 constant TEST_DEADLINE_DAYS_TIER_1 = 7;
uint8 constant TEST_DEADLINE_DAYS_TIER_2 = 14;

/// @title JobCommitmentTestBase
/// @notice Base contract for all JobCommitment tests with common setup and helpers
abstract contract JobCommitmentTestBase is Eip3009TestHelper {
    using MessageHashUtils for bytes32;

    // ============ Contracts ============
    JobCommitment public jobCommitment;
    OrgRegistry public orgRegistry;
    JobFunds public jobFunds;
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
    uint256 public constant APPLICANT_STAKE = 3_000_000; // 3 USDC
    uint96 public constant APPLICANT_STAKE_96 = 3_000_000; // typed mirror for signature helpers
    uint256 public constant DEFAULT_ORG_ID = 1;
    uint256 public constant ORG_OPERATIONAL_BALANCE = 100_000_000_000; // 100,000 USDC
    uint8 public constant DEFAULT_RESPONSE_DEADLINE_DAYS = 3; // tier 0
    address public constant SLASH_BURN_ADDRESS = PROTOCOL_SLASH_BURN_ADDRESS;

    // ============ Nonces ============
    uint256 public applicationNonce;
    uint256 public closeNonce;
    uint256 public expiredSettlementNonce;
    uint256 public creationNonce;
    uint256 public domainVerificationNonce;
    uint256 public orgDomainUpdateNonce;
    uint256 public unpublishNonce;
    uint256 public contentURINonce;

    uint16 internal constant NONCE_SCOPE_JOB_PUBLISH = JobAuthorizationLib.NONCE_SCOPE_JOB_PUBLISH;
    uint16 internal constant NONCE_SCOPE_JOB_CLOSE = JobAuthorizationLib.NONCE_SCOPE_JOB_CLOSE;
    uint16 internal constant NONCE_SCOPE_DOMAIN_VERIFICATION = OrgAuthorizationLib.NONCE_SCOPE_DOMAIN_VERIFICATION;
    uint16 internal constant NONCE_SCOPE_JOB_UNPUBLISH = JobAuthorizationLib.NONCE_SCOPE_JOB_UNPUBLISH;
    uint16 internal constant NONCE_SCOPE_JOB_CONTENT_URI_UPDATE =
        JobAuthorizationLib.NONCE_SCOPE_JOB_CONTENT_URI_UPDATE;
    uint16 internal constant NONCE_SCOPE_ORG_DOMAIN_UPDATE = OrgAuthorizationLib.NONCE_SCOPE_ORG_DOMAIN_UPDATE;
    uint16 internal constant NONCE_SCOPE_JOB_EXPIRED_SETTLEMENT =
        JobAuthorizationLib.NONCE_SCOPE_JOB_EXPIRED_SETTLEMENT;

    // ============ EIP-712 ============
    bytes32 public constant APPLICATION_TYPEHASH = JobAuthorizationLib.APPLICATION_TYPEHASH;
    bytes32 public constant JOB_CLOSE_TYPEHASH = JobAuthorizationLib.JOB_CLOSE_TYPEHASH;
    bytes32 public constant JOB_EXPIRED_SETTLEMENT_TYPEHASH = JobAuthorizationLib.JOB_EXPIRED_SETTLEMENT_TYPEHASH;
    bytes32 public constant JOB_PUBLISH_TYPEHASH = JobAuthorizationLib.JOB_PUBLISH_TYPEHASH;
    bytes32 public constant JOB_UNPUBLISH_TYPEHASH = JobAuthorizationLib.JOB_UNPUBLISH_TYPEHASH;
    bytes32 public constant JOB_CONTENT_URI_UPDATE_TYPEHASH = JobAuthorizationLib.JOB_CONTENT_URI_UPDATE_TYPEHASH;
    bytes32 public constant DOMAIN_VERIFICATION_TYPEHASH = OrgAuthorizationLib.DOMAIN_VERIFICATION_TYPEHASH;
    bytes32 public constant ORG_DOMAIN_UPDATE_TYPEHASH = OrgAuthorizationLib.ORG_DOMAIN_UPDATE_TYPEHASH;

    // ============ Config Helpers ============

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

        // 1. Deploy OrgRegistry
        orgRegistry = new OrgRegistry(owner, address(forwarder), operator);

        // 2. Deploy JobFunds
        jobFunds = new JobFunds(
            IERC20(address(usdc)), IOrgRegistry(address(orgRegistry)), feeRecipient, owner, address(forwarder)
        );

        // 3. Deploy JobCommitment with funding jobFunds
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

        // 4. Authorize JobCommitment in funding jobFunds
        uint32 commitmentVersion = jobCommitment.commitmentVersion();
        vm.prank(owner);
        jobFunds.registerJobCommitment(address(jobCommitment), commitmentVersion);

        vm.prank(owner);
        jobFunds.setCurrentJobCommitment(address(jobCommitment));

        // 5. Create default org for employer
        _createOrgForEmployer(employer, "test.com", DEFAULT_ORG_ID);

        // 6. Fund org job balance
        _fundAndDepositWithAuthorization(
            jobFunds, address(usdc), employerPrivateKey, DEFAULT_ORG_ID, ORG_OPERATIONAL_BALANCE
        );

        _fundApplicant(applicant1);
        _fundApplicant(applicant2);
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

        vm.prank(employerAddr);
        orgRegistry.createOrg(_domainHash(domain), keyNonce, expiry, sig);
    }

    function _domainHash(string memory domain) internal pure returns (bytes32) {
        return keccak256(bytes(domain));
    }

    /// @notice Fund an org with operational balance
    function _fundOrg(uint256 orgId, uint256 treasuryPrivateKey, uint256 amount) internal {
        _fundAndDepositWithAuthorization(jobFunds, address(usdc), treasuryPrivateKey, orgId, amount);
    }

    // ============ Funding Helpers ============

    /// @notice Fund an applicant with 100 USDC and approve JobCommitment
    function _fundApplicant(address account) internal {
        _fundApplicantWithAmount(account, 100_000_000); // 100 USDC
    }

    /// @notice Fund an applicant with specific amount and approve JobCommitment
    function _fundApplicantWithAmount(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(jobCommitment), type(uint256).max);
    }

    function _assertSlashBurned(
        uint256 burnAddressBefore,
        uint256 feeRecipientBefore,
        uint256 expectedSlash,
        string memory message
    ) internal view {
        assertEq(usdc.balanceOf(SLASH_BURN_ADDRESS) - burnAddressBefore, expectedSlash, message);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore, "Fee recipient should not receive slash");
    }

    // ============ Job Helpers ============

    /// @notice Create a job with default stake and specified fee tier
    function _publishJob(uint8 feeTier) internal returns (uint256 jobId) {
        return _publishJobWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, feeTier, "QmTest123");
    }

    /// @notice Create a job with all parameters
    function _publishJobWithParams(uint256 orgId, uint256 stake, uint8 feeTier, string memory contentURI)
        internal
        returns (uint256 jobId)
    {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobPublish(orgId, stake, feeTier, contentURI, employer, keyNonce, expiry);
        return _executeJobPublish(employer, orgId, stake, feeTier, contentURI, keyNonce, expiry, signature);
    }

    /// @notice Create a job with custom employer
    function _publishJobAs(address employerAddr, uint256 orgId, uint256 stake, uint8 feeTier)
        internal
        returns (uint256 jobId)
    {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobPublish(orgId, stake, feeTier, "QmTest123", employerAddr, keyNonce, expiry);
        return _executeJobPublish(employerAddr, orgId, stake, feeTier, "QmTest123", keyNonce, expiry, signature);
    }

    function _executeJobPublish(
        address creator,
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        string memory contentURI,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) internal returns (uint256 jobId) {
        return _executeJobPublishWithFee(
            creator, orgId, stake, feeTier, _jobPublishFee(stake, feeTier), contentURI, keyNonce, expiry, signature
        );
    }

    function _executeJobPublishWithFee(
        address creator,
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        uint256 expectedFeeAmount,
        string memory contentURI,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) internal returns (uint256 jobId) {
        vm.prank(creator);
        return jobFunds.publishJob(
            address(jobCommitment),
            orgId,
            stake,
            expectedFeeAmount,
            feeRecipient,
            abi.encode(feeTier, contentURI, keyNonce, expiry, signature)
        );
    }

    function _jobPublishFee(uint256 stake, uint8 feeTier) internal view returns (uint256 fee) {
        FeeTier memory tier = jobCommitment.feeTier(jobCommitment.currentConfigVersion(), feeTier);
        return tier.baseFee + ((stake * tier.feeBps) / 10_000);
    }

    // ============ Application Helpers ============

    /// @notice Generate a unique applicationId
    function _generateApplicationId(address applicantAddr) internal returns (bytes32) {
        applicationNonce++;
        return keccak256(abi.encodePacked("app", applicantAddr, applicationNonce));
    }

    /// @notice Apply with default stake; jobId is ignored because application signatures bind applicationId, not jobId.
    function _applyToJob(uint256 _ignoredJobId, address applicantAddr) internal returns (bytes32 applicationId) {
        _ignoredJobId;
        return _applyToJobWithStake(applicantAddr, APPLICANT_STAKE);
    }

    /// @notice Apply with default stake.
    function _applyToJob(address applicantAddr) internal returns (bytes32 applicationId) {
        return _applyToJobWithStake(applicantAddr, APPLICANT_STAKE);
    }

    /// @notice Apply with custom stake; jobId is ignored because application signatures bind applicationId, not jobId.
    function _applyToJobWithStake(uint256 _ignoredJobId, address applicantAddr, uint256 stake)
        internal
        returns (bytes32 applicationId)
    {
        _ignoredJobId;
        return _applyToJobWithStake(applicantAddr, stake);
    }

    /// @notice Apply with custom stake using the default response deadline.
    function _applyToJobWithStake(address applicantAddr, uint256 stake) internal returns (bytes32 applicationId) {
        return _applyToJobWithParams(applicantAddr, _toUint96(stake), DEFAULT_RESPONSE_DEADLINE_DAYS);
    }

    /// @notice Apply with full parameter control
    function _applyToJobWithParams(address applicantAddr, uint96 stake, uint8 responseDeadlineDays)
        internal
        returns (bytes32 applicationId)
    {
        applicationId = _generateApplicationId(applicantAddr);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signApplication(applicationId, applicantAddr, stake, responseDeadlineDays, expiry);

        vm.prank(applicantAddr);
        jobCommitment.submitApplication(applicationId, stake, responseDeadlineDays, expiry, signature);
    }

    // ============ Signature Helpers ============

    /// @notice Sign an application with the operator's private key
    function _signApplication(
        bytes32 applicationId,
        address applicantAddr,
        uint96 stake,
        uint8 responseDeadlineDays,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(APPLICATION_TYPEHASH, applicationId, applicantAddr, stake, responseDeadlineDays, expiry)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Sign a job close for the default employer with the operator's private key.
    function _signJobClose(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        return _signJobClose(
            jobId,
            totalApplications,
            respondedApplications,
            onTimeResponses,
            counterSnapshotRoot,
            employer,
            keyNonce,
            expiry
        );
    }

    /// @notice Sign a job close for a specific closer with the operator's private key.
    function _signJobClose(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        address closer,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                JOB_CLOSE_TYPEHASH,
                jobId,
                totalApplications,
                respondedApplications,
                onTimeResponses,
                counterSnapshotRoot,
                closer,
                keyNonce,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Sign an expired settlement with the operator's private key.
    function _signJobExpiredSettlement(
        uint256 jobId,
        uint32 totalApplications,
        uint32 respondedApplications,
        uint32 onTimeResponses,
        bytes32 counterSnapshotRoot,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                JOB_EXPIRED_SETTLEMENT_TYPEHASH,
                jobId,
                totalApplications,
                respondedApplications,
                onTimeResponses,
                counterSnapshotRoot,
                keyNonce,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);

        return abi.encodePacked(r, s, v);
    }

    /// @notice Sign a job creation with the operator's private key
    function _signJobPublish(
        uint256 orgId,
        uint256 stake,
        uint8 feeTier,
        string memory contentURI,
        address creator,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                JOB_PUBLISH_TYPEHASH,
                orgId,
                stake,
                feeTier,
                keccak256(bytes(contentURI)),
                creator,
                jobCommitment.currentConfigVersion(),
                keyNonce,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Sign a job unpublish with the operator's private key.
    function _signJobUnpublish(uint256 jobId, address unpublisher, uint256 keyNonce, uint256 expiry)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(JOB_UNPUBLISH_TYPEHASH, jobId, unpublisher, keyNonce, expiry));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signJobContentURIUpdate(
        uint256 jobId,
        string memory contentURI,
        address updater,
        uint256 keyNonce,
        uint256 expiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(JOB_CONTENT_URI_UPDATE_TYPEHASH, jobId, keccak256(bytes(contentURI)), updater, keyNonce, expiry)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
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
        jobCommitment.recordApplicationResponse(applicationId, responseId);
    }

    /// @notice Record an application response after warping past deadline
    function _respondToApplicationLate(bytes32 applicationId) internal {
        ApplicationView memory app = jobCommitment.application(applicationId);
        // Warp past the response deadline
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
        jobCommitment.recordApplicationResponses(applicationIds, responseIds);
    }

    // ============ Job Lifecycle Helpers ============

    /// @notice Unpublish a job.
    function _unpublishJob(uint256 jobId) internal {
        _unpublishJobAs(jobId, employer);
    }

    /// @notice Unpublish a job as a specific caller.
    function _unpublishJobAs(uint256 jobId, address unpublisher) internal {
        uint256 keyNonce = _nextJobUnpublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobUnpublish(jobId, unpublisher, keyNonce, expiry);
        vm.prank(unpublisher);
        jobCommitment.unpublishJob(jobId, keyNonce, expiry, signature);
    }

    /// @notice Close a job with no applications.
    function _closeJob(uint256 jobId) internal {
        _closeJob(jobId, 0, 0, 0);
    }

    /// @notice Close a job with operator-attested counters.
    function _closeJob(uint256 jobId, uint32 total, uint32 responded, uint32 onTime) internal {
        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(total);
        bytes memory signature = _signJobClose(jobId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry);
        vm.prank(employer);
        jobCommitment.closeJob(jobId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry, signature);
    }

    /// @notice Settle an expired job with no applications (convenience)
    function _settleExpiredJob(uint256 jobId) internal {
        _settleExpiredJob(jobId, 0, 0, 0);
    }

    /// @notice Settle an expired job with operator-attested counters.
    function _settleExpiredJob(uint256 jobId, uint32 total, uint32 responded, uint32 onTime) internal {
        _settleExpiredJobAs(jobId, total, responded, onTime, _counterSnapshotRoot(total), executor);
    }

    /// @notice Settle an expired job as a specific caller.
    function _settleExpiredJobAs(
        uint256 jobId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot,
        address caller
    ) internal {
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(jobId, total, responded, onTime, counterSnapshotRoot);

        vm.prank(caller);
        jobCommitment.settleExpiredJob(
            jobId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry, signature
        );
    }

    function _expiredSettlementAuthorization(
        uint256 jobId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot
    ) internal returns (uint256 keyNonce, uint256 expiry, bytes memory signature) {
        keyNonce = _nextExpiredSettlementKeyNonce();
        expiry = vm.getBlockTimestamp() + 1 hours;
        signature = _signJobExpiredSettlement(jobId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry);
    }

    function _expectExpiredSettlementRevert(
        bytes memory expectedRevert,
        uint256 jobId,
        uint32 total,
        uint32 responded,
        uint32 onTime,
        bytes32 counterSnapshotRoot,
        address caller
    ) internal {
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(jobId, total, responded, onTime, counterSnapshotRoot);

        vm.prank(caller);
        vm.expectRevert(expectedRevert);
        jobCommitment.settleExpiredJob(
            jobId, total, responded, onTime, counterSnapshotRoot, keyNonce, expiry, signature
        );
    }

    /// @notice Build a deterministic non-zero counter root when test counters include applications.
    function _counterSnapshotRoot(uint32 totalApplications) internal pure returns (bytes32) {
        if (totalApplications == 0) return bytes32(0);

        return keccak256(abi.encode("test-counter-snapshot-root", totalApplications));
    }

    // ============ Withdrawal Helpers ============

    /// @notice Withdraw applicant stake through the single-application withdrawStake entrypoint.
    function _withdrawStake(bytes32 applicationId, address applicantAddr) internal {
        vm.prank(applicantAddr);
        jobCommitment.withdrawStake(applicationId);
    }

    // ============ Time Helpers ============

    /// @notice Warp to job expiration time
    function _warpToExpiration(uint256 jobId) internal {
        JobView memory job = jobCommitment.job(jobId);
        vm.warp(job.unpublishedAt + TEST_MAX_UNPUBLISHED_DURATION + 1);
    }

    /// @notice Warp past application response deadline
    function _warpPastDeadline(bytes32 applicationId) internal {
        ApplicationView memory app = jobCommitment.application(applicationId);
        vm.warp(app.responseDeadline + 1);
    }

    // ============ Assertion Helpers ============

    /// @notice Assert job status
    function _assertJobStatus(uint256 jobId, JobStatus expectedStatus) internal view {
        JobView memory job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(expectedStatus), "Unexpected job status");
    }

    /// @notice Assert application responded
    function _assertApplicationResponded(bytes32 applicationId) internal view {
        ApplicationView memory app = jobCommitment.application(applicationId);
        assertTrue(app.isResponded, "Application should be responded");
    }

    /// @notice Get org available balance
    function _getOrgAvailableBalance(uint256 orgId) internal view returns (uint256) {
        return jobFunds.availableBalance(orgId);
    }

    /// @notice Get org operational balance (total, including locked)
    function _getOrgOperationalBalance(uint256 orgId) internal view returns (uint256) {
        OrgJobBalance memory balance = jobFunds.jobBalance(orgId);

        return uint256(balance.available) + uint256(balance.stakedInJobs);
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

    /// @notice Allocate the next job-creation keyNonce.
    function _nextJobPublishKeyNonce() internal returns (uint256) {
        creationNonce++;

        return _packKeyNonce(NONCE_SCOPE_JOB_PUBLISH, creationNonce);
    }

    /// @notice Allocate the next job-close keyNonce.
    function _nextJobCloseKeyNonce() internal returns (uint256) {
        closeNonce++;

        return _packKeyNonce(NONCE_SCOPE_JOB_CLOSE, closeNonce);
    }

    /// @notice Allocate the next expired-settlement keyNonce.
    function _nextExpiredSettlementKeyNonce() internal returns (uint256) {
        expiredSettlementNonce++;

        return _packKeyNonce(NONCE_SCOPE_JOB_EXPIRED_SETTLEMENT, expiredSettlementNonce);
    }

    /// @notice Allocate the next job-unpublish keyNonce.
    function _nextJobUnpublishKeyNonce() internal returns (uint256) {
        unpublishNonce++;

        return _packKeyNonce(NONCE_SCOPE_JOB_UNPUBLISH, unpublishNonce);
    }

    /// @notice Allocate the next job content URI update keyNonce.
    function _nextJobContentURIUpdateKeyNonce() internal returns (uint256) {
        contentURINonce++;

        return _packKeyNonce(NONCE_SCOPE_JOB_CONTENT_URI_UPDATE, contentURINonce);
    }

    /// @notice Allocate a domain-verification keyNonce with deterministic test entropy.
    function _nextDomainVerificationKeyNonce(uint256 salt) internal returns (uint256) {
        domainVerificationNonce++;

        return _packKeyNonce(NONCE_SCOPE_DOMAIN_VERIFICATION, domainVerificationNonce + salt);
    }

    // ============ Deployment Helpers ============

    /// @notice Deploy a new JobCommitment instance with custom token
    function _deployWithToken(IERC20 token) internal returns (JobCommitment) {
        return new JobCommitment(
            token,
            jobFunds,
            owner,
            address(forwarder),
            operator,
            executor,
            _defaultJobConfig(),
            _defaultFeeTiers(),
            TEST_APPLICANT_STAKE
        );
    }
}
