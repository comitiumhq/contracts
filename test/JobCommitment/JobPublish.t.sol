// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {JobView} from "../../src/interfaces/IJobCommitment.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";
import {Errors} from "../../src/Errors.sol";
import {TEST_TIER_0_BASE_FEE, TEST_TIER_1_BASE_FEE, TEST_TIER_2_BASE_FEE, TEST_MIN_STAKE} from "../shared/TestBase.sol";

/// @title JobPublishTest
/// @notice Tests for job creation functionality
contract JobPublishTest is JobCommitmentTestBase {
    function test_publishJob_success() public {
        uint256 feeRecipientBalBefore = usdc.balanceOf(feeRecipient);

        uint256 jobId = _publishJobWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest123");

        assertEq(jobId, 1);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(job.creator, employer);
        assertEq(job.orgId, DEFAULT_ORG_ID);
        assertEq(job.stake, EMPLOYER_STAKE);
        assertEq(job.feeTier, 0);
        assertEq(uint8(job.status), uint8(JobStatus.Published));
        assertEq(job.contentURI, "QmTest123");

        // Fee goes to the protocol fee recipient; stake stays accounted in JobFunds.
        uint256 expectedFee = TEST_TIER_0_BASE_FEE + ((EMPLOYER_STAKE * 150) / 10_000);
        assertEq(usdc.balanceOf(address(jobCommitment)), 0);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalBefore + expectedFee);
    }

    function test_publishJob_stakeTooLow_reverts() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, TEST_MIN_STAKE - 1, 0, "QmTest", employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(TEST_MIN_STAKE - 1, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.StakeTooLow.selector, TEST_MIN_STAKE - 1, TEST_MIN_STAKE));
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, TEST_MIN_STAKE - 1, 0, expectedFee, "QmTest", keyNonce, expiry, signature
        );
    }

    function test_publishJob_invalidFeeTier_reverts() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 3, "QmTest", employer, keyNonce, expiry);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidFeeTier.selector, 3));
        _executeJobPublishWithFee(employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 3, 0, "QmTest", keyNonce, expiry, signature);
    }

    function test_publishJob_jobManager_succeeds() public {
        vm.prank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, true);

        uint256 jobId = _publishJobAs(applicant1, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(job.creator, applicant1);
        assertEq(job.orgId, DEFAULT_ORG_ID);
    }

    function test_publishJob_nonManagerWithValidSignature_reverts() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest", applicant1, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobManager.selector, DEFAULT_ORG_ID, applicant1));
        _executeJobPublishWithFee(
            applicant1, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, "QmTest", keyNonce, expiry, signature
        );
    }

    function test_publishJob_revokedJobManager_reverts() public {
        vm.startPrank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, true);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, false);
        vm.stopPrank();

        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest", applicant1, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobManager.selector, DEFAULT_ORG_ID, applicant1));
        _executeJobPublishWithFee(
            applicant1, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, "QmTest", keyNonce, expiry, signature
        );
    }

    function test_publishJob_emptyContentURI_reverts() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "", employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.EmptyContentURI.selector);
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, "", keyNonce, expiry, signature
        );
    }

    function test_publishJob_feeAmountMismatch_revertsWithoutDebit() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmFeeMismatch", employer, keyNonce, expiry);
        uint256 availableBefore = jobFunds.availableBalance(DEFAULT_ORG_ID);
        uint256 recipientBalanceBefore = usdc.balanceOf(feeRecipient);

        vm.expectRevert(abi.encodeWithSelector(Errors.FeeAmountMismatch.selector, expectedFee + 1, expectedFee));
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee + 1, "QmFeeMismatch", keyNonce, expiry, signature
        );

        assertEq(jobFunds.availableBalance(DEFAULT_ORG_ID), availableBefore);
        assertEq(usdc.balanceOf(feeRecipient), recipientBalanceBefore);
        assertEq(jobCommitment.nextJobId(), 1);
    }

    function test_publishJob_feeRecipientMismatch_revertsWithoutDebit() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmRecipientMismatch", employer, keyNonce, expiry);
        uint256 availableBefore = jobFunds.availableBalance(DEFAULT_ORG_ID);
        address unexpectedRecipient = makeAddr("unexpectedRecipient");
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.FeeRecipientMismatch.selector, unexpectedRecipient, feeRecipient));
        jobFunds.publishJob(
            address(jobCommitment),
            DEFAULT_ORG_ID,
            EMPLOYER_STAKE,
            expectedFee,
            unexpectedRecipient,
            abi.encode(uint8(0), "QmRecipientMismatch", keyNonce, expiry, signature)
        );

        assertEq(jobFunds.availableBalance(DEFAULT_ORG_ID), availableBefore);
        assertEq(usdc.balanceOf(unexpectedRecipient), 0);
        assertEq(jobCommitment.nextJobId(), 1);
    }

    function test_createJob_revert_callerIsNotJobFunds() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmDirect", employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotJobFunds.selector, employer));
        jobCommitment.createJob(
            DEFAULT_ORG_ID,
            employer,
            EMPLOYER_STAKE,
            expectedFee,
            abi.encode(uint8(0), "QmDirect", keyNonce, expiry, signature)
        );
    }

    function test_publishJob_allFeeTiers_correctFees() public {
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 tier0Fee = TEST_TIER_0_BASE_FEE + ((EMPLOYER_STAKE * 150) / 10_000);
        uint256 tier1Fee = TEST_TIER_1_BASE_FEE + ((EMPLOYER_STAKE * 250) / 10_000);
        uint256 tier2Fee = TEST_TIER_2_BASE_FEE + ((EMPLOYER_STAKE * 350) / 10_000);

        uint256 jobId0 = _publishJobWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTier0");
        JobView memory job0 = jobCommitment.job(jobId0);
        assertEq(job0.feeTier, 0);
        assertEq(job0.feeAmount, tier0Fee);

        uint256 jobId1 = _publishJobWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 1, "QmTier1");
        JobView memory job1 = jobCommitment.job(jobId1);
        assertEq(job1.feeTier, 1);
        assertEq(job1.feeAmount, tier1Fee);

        uint256 jobId2 = _publishJobWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 2, "QmTier2");
        JobView memory job2 = jobCommitment.job(jobId2);
        assertEq(job2.feeTier, 2);
        assertEq(job2.feeAmount, tier2Fee);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + tier0Fee + tier1Fee + tier2Fee);
    }

    function test_nextJobId() public view {
        assertEq(jobCommitment.nextJobId(), 1);
    }

    // ============ EIP-712 Signature Tests ============

    function test_publishJob_expiredSignature_reverts() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest", employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.warp(expiry + 1);

        vm.expectRevert(Errors.SignatureExpired.selector);
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, "QmTest", keyNonce, expiry, signature
        );
    }

    function test_publishJob_expiryAtCurrentTimestamp_succeeds() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmBoundary", employer, keyNonce, expiry);

        uint256 jobId =
            _executeJobPublish(employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmBoundary", keyNonce, expiry, signature);

        assertEq(jobId, 1);
    }

    function test_publishJob_invalidSignature_wrongSigner_reverts() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        uint256 wrongKey = 0x9999;
        bytes32 structHash = keccak256(
            abi.encode(
                JOB_PUBLISH_TYPEHASH,
                DEFAULT_ORG_ID,
                EMPLOYER_STAKE,
                uint8(0),
                keccak256(bytes("QmTest")),
                employer,
                jobCommitment.currentConfigVersion(),
                keyNonce,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.InvalidSignature.selector);
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, "QmTest", keyNonce, expiry, badSig
        );
    }

    function test_publishJob_staleConfigSignature_revertsAfterConfigUpdate() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmStaleConfig", employer, keyNonce, expiry);

        vm.prank(owner);
        jobCommitment.setJobConfig(_defaultJobConfig(), _defaultFeeTiers());
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.InvalidSignature.selector);
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, "QmStaleConfig", keyNonce, expiry, signature
        );
    }

    function test_publishJob_nonceReplay_reverts() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest1", employer, keyNonce, expiry);
        _executeJobPublish(employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest1", keyNonce, expiry, signature);

        bytes memory signature2 =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest2", employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSignature("InvalidAccountNonce(address,uint256)", operator, keyNonce + 1));
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, "QmTest2", keyNonce, expiry, signature2
        );
    }

    function test_publishJob_wrongNonceScope_reverts() public {
        uint256 keyNonce = _packKeyNonce(NONCE_SCOPE_JOB_CLOSE, 1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest", employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidNonceScope.selector, NONCE_SCOPE_JOB_CLOSE, NONCE_SCOPE_JOB_PUBLISH)
        );
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, "QmTest", keyNonce, expiry, signature
        );
    }

    function test_publishJob_mismatchedParams_reverts() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest", employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE + 1, 0);

        vm.expectRevert(Errors.InvalidSignature.selector);
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE + 1, 0, expectedFee, "QmTest", keyNonce, expiry, signature
        );
    }

    function test_publishJob_mismatchedCreator_reverts() public {
        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;

        vm.prank(employer);
        jobFunds.setJobManager(DEFAULT_ORG_ID, applicant1, true);

        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmTest", employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.InvalidSignature.selector);
        _executeJobPublishWithFee(
            applicant1, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, "QmTest", keyNonce, expiry, signature
        );
    }
}
