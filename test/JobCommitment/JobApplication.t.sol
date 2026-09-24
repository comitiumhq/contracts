// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {ApplicationView} from "../../src/interfaces/IJobCommitment.sol";
import {APPLICATION_DEADLINE_DAYS_UPPER} from "../../src/libraries/ConfigValidationLib.sol";
import {Errors} from "../../src/Errors.sol";

contract JobApplicationTest is JobCommitmentTestBase {
    function test_submitApplication_recordsApplicant() public {
        uint256 applicantBalance = 100_000_000;
        usdc.mint(applicant1, applicantBalance);

        bytes32 applicationId = _submitApplication(applicant1);

        ApplicationView memory application = jobCommitment.application(applicationId);
        assertEq(application.applicant, applicant1);
        assertGt(application.appliedAt, 0);
        assertFalse(application.isResponded);
        assertEq(usdc.balanceOf(applicant1), applicantBalance);
        assertEq(usdc.balanceOf(address(jobCommitment)), 0);
    }

    function test_submitApplication_rejectsReusedId() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory firstSignature =
            _signApplication(applicationId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);
        vm.prank(applicant1);
        jobCommitment.submitApplication(applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, firstSignature);

        bytes memory secondSignature =
            _signApplication(applicationId, applicant2, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);
        vm.prank(applicant2);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApplicationIdAlreadyUsed.selector, applicationId));
        jobCommitment.submitApplication(applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, secondSignature);
    }

    function test_submitApplication_rejectsOtherApplicant() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signApplication(applicationId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant2);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.submitApplication(applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature);
    }

    function test_submitApplication_rejectsOtherDeadline() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signApplication(applicationId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.submitApplication(applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS + 1, expiry, signature);
    }

    function test_submitApplication_rejectsExecutorSignature() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(APPLICATION_TYPEHASH, applicationId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", jobCommitment.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(executorPrivateKey, digest);

        vm.prank(applicant1);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.submitApplication(
            applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, abi.encodePacked(r, s, v)
        );
    }

    function test_submitApplication_rejectsExpiredSignature() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signApplication(applicationId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);
        vm.warp(expiry + 1);

        vm.prank(applicant1);
        vm.expectRevert(Errors.SignatureExpired.selector);
        jobCommitment.submitApplication(applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature);
    }

    function test_submitApplication_acceptsAtExpiry() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint256 expiry = block.timestamp;
        bytes memory signature = _signApplication(applicationId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant1);
        jobCommitment.submitApplication(applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature);

        assertEq(jobCommitment.application(applicationId).applicant, applicant1);
    }

    function test_submitApplication_rejectsInvalidFields() public {
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 applicationId = _generateApplicationId(applicant1);
        vm.startPrank(applicant1);

        vm.expectRevert(Errors.ZeroApplicationId.selector);
        jobCommitment.submitApplication(bytes32(0), DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, "");

        vm.expectRevert(Errors.InvalidDeadline.selector);
        jobCommitment.submitApplication(applicationId, 0, expiry, "");

        vm.expectRevert(Errors.InvalidDeadline.selector);
        jobCommitment.submitApplication(applicationId, APPLICATION_DEADLINE_DAYS_UPPER + 1, expiry, "");
        vm.stopPrank();
    }
}
