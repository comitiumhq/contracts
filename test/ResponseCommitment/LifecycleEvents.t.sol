// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {
    ResponseCommitmentTestBase,
    TEST_TIER_0_BASE_FEE,
    TEST_FEE_TIER_0,
    TEST_DEADLINE_DAYS_TIER_0,
    TEST_MAX_ACTIVE_DURATION,
    TEST_MAX_STOPPED_DURATION
} from "../shared/TestBase.sol";
import {IResponseCommitment, CommitmentView} from "../../src/interfaces/IResponseCommitment.sol";

/// @title LifecycleEventsTest
/// @notice Asserts canonical lifecycle event payloads.
contract LifecycleEventsTest is ResponseCommitmentTestBase {
    function test_commitmentActive_emitsFullPayload() public {
        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest123"), employer, keyNonce, expiry
        );

        uint256 expectedFee = TEST_TIER_0_BASE_FEE + (EMPLOYER_STAKE * TEST_FEE_TIER_0) / 10000;

        // commitmentId (topic1) is contract-assigned, so it is not checked; everything else is.
        vm.expectEmit(false, true, true, true, address(responseCommitment));
        emit IResponseCommitment.CommitmentActivated(
            0,
            DEFAULT_ORG_ID,
            employer,
            1,
            EMPLOYER_STAKE,
            expectedFee,
            TEST_DEADLINE_DAYS_TIER_0,
            keccak256("QmTest123")
        );

        _executeCommitmentActivation(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmTest123"), keyNonce, expiry, sig
        );
    }

    function test_commitmentStopped_emitsFullPayload() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 keyNonce = _nextCommitmentStopKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentStop(commitmentId, employer, keyNonce, expiry);

        vm.expectEmit(true, true, true, true, address(responseCommitment));
        emit IResponseCommitment.CommitmentStopped(commitmentId, DEFAULT_ORG_ID, employer);

        vm.prank(employer);
        responseCommitment.stopCommitment(commitmentId, keyNonce, expiry, sig);
    }

    function test_applicationSubmitted_emitsFullPayload() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint8 deadlineDays = DEFAULT_RESPONSE_DEADLINE_DAYS;
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signApplication(applicationId, applicant1, deadlineDays, expiry);

        uint256 expectedResponseDeadline = block.timestamp + uint256(deadlineDays) * 1 days;

        vm.expectEmit(true, true, false, true, address(responseCommitment));
        emit IResponseCommitment.ApplicationSubmitted(
            applicationId,
            applicant1,
            expectedResponseDeadline,
            keccak256(abi.encodeCall(responseCommitment.submitApplication, (applicationId, deadlineDays, expiry, sig)))
        );

        vm.prank(applicant1);
        responseCommitment.submitApplication(applicationId, deadlineDays, expiry, sig);
    }

    function test_applicationSubmitted_forwardedHashesCanonicalCalldata() public {
        bytes32 applicationId = _generateApplicationId(applicant1);
        uint8 deadlineDays = DEFAULT_RESPONSE_DEADLINE_DAYS;
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signApplication(applicationId, applicant1, deadlineDays, expiry);
        bytes memory callData =
            abi.encodeCall(responseCommitment.submitApplication, (applicationId, deadlineDays, expiry, sig));
        uint256 expectedResponseDeadline = block.timestamp + uint256(deadlineDays) * 1 days;

        vm.expectEmit(true, true, false, true, address(responseCommitment));
        emit IResponseCommitment.ApplicationSubmitted(
            applicationId, applicant1, expectedResponseDeadline, keccak256(callData)
        );

        _forwardAs(applicant1, address(responseCommitment), callData);
    }

    function test_commitmentSettled_emitsCountersAndConservedStake() public {
        uint256 commitmentId = _activateCommitment(0);
        uint256 stake = responseCommitment.commitment(commitmentId).stake;

        vm.recordLogs();
        _settleCommitment(commitmentId, 0, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic0 = keccak256(
            "CommitmentSettled(uint256,uint256,address,uint32,uint32,uint32,bytes32,uint256,uint256,uint256)"
        );

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != topic0) continue;
            found = true;

            assertEq(uint256(logs[i].topics[1]), commitmentId, "CommitmentSettled commitmentId");
            assertEq(uint256(logs[i].topics[2]), DEFAULT_ORG_ID, "CommitmentSettled orgId");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), employer, "CommitmentSettled actor");

            (uint32 total, uint32 responded, uint32 onTime,,, uint256 stakeReturned, uint256 stakeSlashed) =
                abi.decode(logs[i].data, (uint32, uint32, uint32, bytes32, uint256, uint256, uint256));

            assertEq(total, 0, "total");
            assertEq(responded, 0, "responded");
            assertEq(onTime, 0, "onTime");
            assertEq(stakeReturned + stakeSlashed, stake, "CommitmentSettled must conserve stake");
        }

        assertTrue(found, "CommitmentSettled event not emitted");
    }

    function test_expiredSettlementFromActive_emitsStoppedThenExpired() public {
        uint256 commitmentId = _activateCommitment(0);
        vm.warp(block.timestamp + TEST_MAX_ACTIVE_DURATION + 1);

        vm.recordLogs();
        _settleExpiredCommitment(commitmentId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 stoppedTopic = keccak256("CommitmentStopped(uint256,uint256,address)");
        bytes32 expiredTopic = keccak256(
            "ExpiredCommitmentSettled(uint256,uint256,address,uint32,uint32,uint32,bytes32,uint256,uint256,uint256)"
        );
        (uint256 stoppedIndex, bool foundStopped) = _findEvent(logs, stoppedTopic);
        (uint256 expiredIndex, bool foundExpired) = _findEvent(logs, expiredTopic);

        assertTrue(foundStopped, "CommitmentStopped event not emitted");
        assertTrue(foundExpired, "ExpiredCommitmentSettled event not emitted");
        assertLt(stoppedIndex, expiredIndex, "CommitmentStopped must precede ExpiredCommitmentSettled");
    }

    function test_expiredSettlementFromStopped_doesNotEmitStoppedAgain() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        vm.warp(commitment.stoppedAt + TEST_MAX_STOPPED_DURATION + 1);

        vm.recordLogs();
        _settleExpiredCommitment(commitmentId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 stoppedTopic = keccak256("CommitmentStopped(uint256,uint256,address)");
        (, bool foundStopped) = _findEvent(logs, stoppedTopic);

        assertFalse(foundStopped, "CommitmentStopped emitted twice");
    }

    function _findEvent(Vm.Log[] memory logs, bytes32 topic) private pure returns (uint256 index, bool found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) return (i, true);
        }

        return (0, false);
    }
}
