// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {ApplicationView} from "../../src/interfaces/IJobCommitment.sol";
import {APPLICATION_DEADLINE_DAYS_UPPER} from "../../src/libraries/ConfigValidationLib.sol";
import {Errors} from "../../src/Errors.sol";

/// @title JobApplicationTest
/// @notice Tests for job application functionality including signatures
contract JobApplicationTest is JobCommitmentTestBase {
    // ============ Basic Application Tests ============

    function test_submitApplication_success() public {
        uint256 jobId = _publishJob(0);
        uint256 applicantBalanceBefore = usdc.balanceOf(applicant1);

        bytes32 appId = _applyToJob(jobId, applicant1);

        ApplicationView memory app = jobCommitment.application(appId);
        assertEq(app.applicant, applicant1);
        assertEq(app.stake, APPLICANT_STAKE);
        assertTrue(app.appliedAt > 0);
        assertFalse(app.isResponded);

        assertEq(usdc.balanceOf(applicant1), applicantBalanceBefore - APPLICANT_STAKE);
    }

    function test_submitApplication_nonCurrentStake_reverts() public {
        _publishJob(0);
        uint96 nonCurrentStake = 6_000_000;

        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signApplication(applicationId, applicant1, nonCurrentStake, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant1);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidApplicantStake.selector, nonCurrentStake, APPLICANT_STAKE_96)
        );
        jobCommitment.submitApplication(
            applicationId, nonCurrentStake, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature
        );
    }

    function test_submitApplication_currentAmountAfterUpdate_succeeds() public {
        _publishJob(0);
        uint96 newAmount = 7_000_000;

        vm.prank(owner);
        jobCommitment.setApplicantStakeAmount(newAmount);

        bytes32 appId = _applyToJobWithStake(applicant1, newAmount);
        assertEq(jobCommitment.application(appId).stake, newAmount);
    }

    function test_submitApplication_signedOldAmountAfterUpdate_reverts() public {
        _publishJob(0);
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        uint256 applicantBalanceBefore = usdc.balanceOf(applicant1);
        uint256 contractBalanceBefore = usdc.balanceOf(address(jobCommitment));
        bytes memory signature =
            _signApplication(applicationId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(owner);
        jobCommitment.setApplicantStakeAmount(7_000_000);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidApplicantStake.selector, APPLICANT_STAKE_96, 7_000_000));
        jobCommitment.submitApplication(
            applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature
        );

        assertEq(usdc.balanceOf(applicant1), applicantBalanceBefore);
        assertEq(usdc.balanceOf(address(jobCommitment)), contractBalanceBefore);
        assertEq(jobCommitment.totalApplicantStakes(), 0);
        assertFalse(jobCommitment.isApplicationIdUsed(applicationId));
    }

    // ============ Application ID Tests ============

    function test_submitApplication_applicationIdAlreadyUsed_reverts() public {
        _publishJob(0);

        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig1 =
            _signApplication(applicationId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant1);
        jobCommitment.submitApplication(applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, sig1);

        // Try to reuse same applicationId with different applicant
        bytes memory sig2 =
            _signApplication(applicationId, applicant2, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant2);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApplicationIdAlreadyUsed.selector, applicationId));
        jobCommitment.submitApplication(applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, sig2);
    }

    // ============ Signature Validation Tests ============

    function test_submitApplication_invalidSignature_reverts() public {
        _publishJob(0);
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(
                APPLICATION_TYPEHASH,
                applicationId,
                applicant1,
                APPLICANT_STAKE_96,
                DEFAULT_RESPONSE_DEADLINE_DAYS,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x9999, digest);
        bytes memory badSignature = abi.encodePacked(r, s, v);

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.submitApplication(
            applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, badSignature
        );
    }

    function test_submitApplication_executorSignature_reverts() public {
        _publishJob(0);
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                APPLICATION_TYPEHASH,
                applicationId,
                applicant1,
                APPLICANT_STAKE_96,
                DEFAULT_RESPONSE_DEADLINE_DAYS,
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(executorPrivateKey, digest);
        bytes memory executorSignature = abi.encodePacked(r, s, v);

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.submitApplication(
            applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, executorSignature
        );
    }

    function test_submitApplication_expiredSignature_reverts() public {
        _publishJob(0);
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signApplication(applicationId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(applicant1);
        vm.expectRevert(Errors.SignatureExpired.selector);
        jobCommitment.submitApplication(
            applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature
        );
    }

    function test_submitApplication_expiryAtCurrentTimestamp_succeeds() public {
        _publishJob(0);
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp;
        bytes memory signature =
            _signApplication(applicationId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant1);
        jobCommitment.submitApplication(
            applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature
        );

        ApplicationView memory app = jobCommitment.application(applicationId);
        assertEq(app.applicant, applicant1);
    }

    function test_submitApplication_configUpdateDoesNotInvalidateSignature() public {
        _publishJob(0);
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signApplication(applicationId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(owner);
        jobCommitment.setJobConfig(_defaultJobConfig(), _defaultFeeTiers());

        vm.prank(applicant1);
        jobCommitment.submitApplication(
            applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature
        );

        ApplicationView memory app = jobCommitment.application(applicationId);
        assertEq(app.applicant, applicant1);
    }

    function test_submitApplication_signatureForDifferentApplicant_reverts() public {
        _publishJob(0);
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;

        bytes memory signature =
            _signApplication(applicationId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant2);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.submitApplication(
            applicationId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature
        );
    }

    // ============ Defense-in-depth: Zero stake / Zero responseDeadlineDays ============

    function test_submitApplication_zeroApplicationId_reverts() public {
        _publishJob(0);

        vm.prank(applicant1);
        vm.expectRevert(Errors.ZeroApplicationId.selector);
        jobCommitment.submitApplication(
            bytes32(0), APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, block.timestamp + 1 hours, bytes("")
        );
    }

    function test_submitApplication_zeroStake_reverts() public {
        _publishJob(0);

        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidApplicantStake.selector, uint96(0), APPLICANT_STAKE_96));
        jobCommitment.submitApplication(applicationId, 0, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, bytes(""));
    }

    function test_submitApplication_zeroResponseDeadlineDays_reverts() public {
        _publishJob(0);

        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidDeadline.selector);
        jobCommitment.submitApplication(applicationId, APPLICANT_STAKE_96, 0, expiry, bytes(""));
    }

    function test_submitApplication_deadlineAboveProtocolUpperBound_reverts() public {
        _publishJob(0);

        uint8 invalidDeadline = APPLICATION_DEADLINE_DAYS_UPPER + 1;
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidDeadline.selector);
        jobCommitment.submitApplication(applicationId, APPLICANT_STAKE_96, invalidDeadline, expiry, bytes(""));
    }

    // ============ Stake from Operator Signature ============

    function test_submitApplication_signatureForDifferentStake_reverts() public {
        _publishJob(0);

        uint96 currentStake = 7_000_000;
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signApplication(applicationId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(owner);
        jobCommitment.setApplicantStakeAmount(currentStake);

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.submitApplication(applicationId, currentStake, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature);
    }
}
