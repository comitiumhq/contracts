// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase, TEST_MAX_STOPPED_DURATION} from "../shared/TestBase.sol";

/// @title PauseTest
/// @notice Tests for pause/unpause functionality
contract PauseTest is ResponseCommitmentTestBase {
    // ============ Pause State Blocking Tests ============

    function test_pause_activateCommitment_reverts() public {
        vm.prank(owner);
        responseCommitment.pause();

        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, signature
        );
    }

    function test_pause_submitApplication_reverts() public {
        vm.prank(owner);
        responseCommitment.pause();

        bytes32 applicationId = keccak256("testAppId");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signApplication(applicationId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        responseCommitment.submitApplication(applicationId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, sig);
    }

    function test_pause_recordApplicationResponse_allowed() public {
        bytes32 appId = _submitApplication(applicant1);

        vm.prank(owner);
        responseCommitment.pause();

        _respondToApplication(appId);
        _assertApplicationResponded(appId);
    }

    function test_pause_stopCommitment_reverts() public {
        uint256 commitmentId = _activateCommitment(0);

        vm.prank(owner);
        responseCommitment.pause();

        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentStop(commitmentId, employer, keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, signature);
    }

    // ============ Critical Operations Allowed When Paused ============

    function test_pause_settleCommitment_allowed() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 availableBefore = _getOrgAvailableBalance(DEFAULT_ORG_ID);

        vm.prank(owner);
        responseCommitment.pause();

        _settleCommitment(commitmentId);

        assertEq(_getOrgAvailableBalance(DEFAULT_ORG_ID), availableBefore + EMPLOYER_STAKE);
    }

    function test_pause_settleExpiredCommitment_allowed() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 availableBefore = _getOrgAvailableBalance(DEFAULT_ORG_ID);

        _stopCommitment(commitmentId);

        vm.prank(owner);
        responseCommitment.pause();

        vm.warp(block.timestamp + TEST_MAX_STOPPED_DURATION + 1);

        _settleExpiredCommitment(commitmentId);

        assertEq(_getOrgAvailableBalance(DEFAULT_ORG_ID), availableBefore + EMPLOYER_STAKE);
    }

    // ============ Pause/Unpause Control Tests ============

    function test_pause_unpause() public {
        vm.prank(owner);
        responseCommitment.pause();

        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"), employer, keyNonce, expiry
        );
        uint256 expectedFee = _commitmentActivateFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmTest"), keyNonce, expiry, signature
        );

        vm.prank(owner);
        responseCommitment.unpause();

        uint256 commitmentId = _activateCommitmentWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest"));
        assertEq(commitmentId, 1);
    }

    function test_pause_onlyOwner() public {
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        responseCommitment.pause();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        responseCommitment.pause();

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", applicant1));
        responseCommitment.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        responseCommitment.pause();

        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        responseCommitment.unpause();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", operator));
        responseCommitment.unpause();
    }
}
