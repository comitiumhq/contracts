// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {TEST_APPLICANT_STAKE, TEST_MIN_STAKE} from "../shared/TestBase.sol";

/// @title FuzzTest
/// @notice Fuzz tests for JobCommitment contract
contract FuzzTest is JobCommitmentTestBase {
    // ============ Create Job Fuzz Tests ============

    function testFuzz_publishJob_belowMinStake_reverts(uint256 stake) public {
        stake = bound(stake, 1, TEST_MIN_STAKE - 1);

        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signJobPublish(DEFAULT_ORG_ID, stake, 0, "QmFuzz", employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(stake, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.StakeTooLow.selector, stake, TEST_MIN_STAKE));
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, stake, 0, expectedFee, "QmFuzz", keyNonce, expiry, signature
        );
    }

    // ============ Apply to Job Fuzz Tests ============

    function testFuzz_submitApplication_nonCurrentStake_reverts(uint96 stake) public {
        _publishJob(0);
        vm.assume(stake != TEST_APPLICANT_STAKE);

        address applicant = makeAddr("fuzzApplicant");
        usdc.mint(applicant, stake);
        vm.prank(applicant);
        usdc.approve(address(jobCommitment), type(uint256).max);

        bytes32 applicationId = _generateApplicationId(applicant);
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signApplication(applicationId, applicant, stake, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidApplicantStake.selector, stake, TEST_APPLICANT_STAKE));
        jobCommitment.submitApplication(applicationId, stake, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, sig);
    }

    // ============ Fee Tier Fuzz Tests ============

    function testFuzz_feeTiers_invalid_reverts(uint8 feeTier) public {
        feeTier = uint8(bound(feeTier, 3, 255));

        uint256 keyNonce = _nextJobPublishKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, feeTier, "QmFuzz", employer, keyNonce, expiry);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidFeeTier.selector, feeTier));
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, feeTier, 0, "QmFuzz", keyNonce, expiry, signature
        );
    }
}
