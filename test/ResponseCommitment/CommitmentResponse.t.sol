// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {IResponseCommitment, ApplicationView} from "../../src/interfaces/IResponseCommitment.sol";

uint256 constant TEST_MAX_BATCH_SIZE = 50;

/// @title CommitmentResponseTest
/// @notice Tests for responding to applications
contract CommitmentResponseTest is ResponseCommitmentTestBase {
    function test_recordApplicationResponse_success() public {
        bytes32 appId = _submitApplication(applicant1);

        _respondToApplication(appId);

        ApplicationView memory app = responseCommitment.application(appId);
        assertTrue(app.isResponded);
        assertTrue(app.respondedAt > 0);
    }

    function test_recordApplicationResponse_emitsEvent() public {
        bytes32 appId = _submitApplication(applicant1);
        bytes32 responseId = _generateResponseId(appId);

        vm.expectEmit(true, true, false, true);
        emit IResponseCommitment.ApplicationResponded(appId, executor, responseId);

        vm.prank(executor);
        responseCommitment.recordApplicationResponse(appId, responseId);
    }

    function test_recordApplicationResponse_eventTopicMatchesAbi() public {
        bytes32 appId = _submitApplication(applicant1);
        bytes32 responseId = _generateResponseId(appId);

        vm.recordLogs();
        vm.prank(executor);
        responseCommitment.recordApplicationResponse(appId, responseId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("ApplicationResponded(bytes32,address,bytes32)"));
        assertEq(logs[0].topics[1], appId);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), executor);
        assertEq(abi.decode(logs[0].data, (bytes32)), responseId);
    }

    function test_responseFunctionSelectors_matchConsumerAbi() public pure {
        assertEq(
            IResponseCommitment.recordApplicationResponse.selector,
            bytes4(keccak256("recordApplicationResponse(bytes32,bytes32)"))
        );
        assertEq(
            IResponseCommitment.recordApplicationResponses.selector,
            bytes4(keccak256("recordApplicationResponses(bytes32[],bytes32[])"))
        );
    }

    function test_recordApplicationResponse_exactlyAtDeadline_succeeds() public {
        bytes32 appId = _submitApplication(applicant1);
        ApplicationView memory before = responseCommitment.application(appId);

        vm.warp(before.responseDeadline);
        _respondToApplication(appId);

        ApplicationView memory after_ = responseCommitment.application(appId);
        assertTrue(after_.isResponded);
        assertEq(after_.respondedAt, before.responseDeadline);
    }

    function test_recordApplicationResponse_alreadyResponded_reverts() public {
        bytes32 appId = _submitApplication(applicant1);

        _respondToApplication(appId);

        bytes32 responseId = _generateResponseId(appId);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApplicationAlreadyResponded.selector, appId));
        responseCommitment.recordApplicationResponse(appId, responseId);
    }

    function test_recordApplicationResponse_applicationNotFound_reverts() public {
        bytes32 fakeAppId = keccak256("nonexistent");
        bytes32 responseId = _generateResponseId(fakeAppId);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApplicationNotFound.selector, fakeAppId));
        responseCommitment.recordApplicationResponse(fakeAppId, responseId);
    }

    function test_recordApplicationResponse_zeroApplicationId_reverts() public {
        vm.prank(executor);
        vm.expectRevert(Errors.ZeroApplicationId.selector);
        responseCommitment.recordApplicationResponse(bytes32(0), keccak256("response"));
    }

    function test_recordApplicationResponse_zeroResponseId_reverts() public {
        bytes32 appId = _submitApplication(applicant1);

        vm.prank(executor);
        vm.expectRevert(Errors.ZeroResponseId.selector);
        responseCommitment.recordApplicationResponse(appId, bytes32(0));
    }

    function test_recordApplicationResponse_nonExecutor_reverts() public {
        bytes32 appId = _submitApplication(applicant1);

        bytes32 responseId = _generateResponseId(appId);
        vm.prank(employer);
        vm.expectRevert(Errors.NotExecutor.selector);
        responseCommitment.recordApplicationResponse(appId, responseId);
    }

    function test_recordApplicationResponse_operatorCannotExecute() public {
        bytes32 appId = _submitApplication(applicant1);
        bytes32 responseId = _generateResponseId(appId);

        vm.prank(operator);
        vm.expectRevert(Errors.NotExecutor.selector);
        responseCommitment.recordApplicationResponse(appId, responseId);
    }

    function test_recordApplicationResponse_executor_success() public {
        bytes32 appId = _submitApplication(applicant1);

        _respondToApplicationAs(appId, executor);

        ApplicationView memory app = responseCommitment.application(appId);
        assertTrue(app.isResponded);
    }

    // ============ Batch Respond Tests ============

    function test_recordApplicationResponses_success() public {
        bytes32 appId1 = _submitApplication(applicant1);
        bytes32 appId2 = _submitApplication(applicant2);

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId1;
        appIds[1] = appId2;

        _batchRespondToApplications(appIds);

        ApplicationView memory app1 = responseCommitment.application(appId1);
        ApplicationView memory app2 = responseCommitment.application(appId2);
        assertTrue(app1.isResponded);
        assertTrue(app2.isResponded);
        assertTrue(app1.respondedAt > 0);
        assertTrue(app2.respondedAt > 0);
    }

    function test_recordApplicationResponses_singleApplication() public {
        bytes32 appId = _submitApplication(applicant1);

        bytes32[] memory appIds = new bytes32[](1);
        appIds[0] = appId;

        _batchRespondToApplications(appIds);

        ApplicationView memory app = responseCommitment.application(appId);
        assertTrue(app.isResponded);
    }

    function test_recordApplicationResponses_emitsEventsForEach() public {
        bytes32 appId1 = _submitApplication(applicant1);
        bytes32 appId2 = _submitApplication(applicant2);

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId1;
        appIds[1] = appId2;

        bytes32[] memory responseIds = new bytes32[](2);
        responseIds[0] = _generateResponseId(appId1);
        responseIds[1] = _generateResponseId(appId2);

        vm.expectEmit(true, true, false, true);
        emit IResponseCommitment.ApplicationResponded(appId1, executor, responseIds[0]);
        vm.expectEmit(true, true, false, true);
        emit IResponseCommitment.ApplicationResponded(appId2, executor, responseIds[1]);

        vm.prank(executor);
        responseCommitment.recordApplicationResponses(appIds, responseIds);
    }

    function test_recordApplicationResponses_emptyBatch_reverts() public {
        bytes32[] memory appIds = new bytes32[](0);
        bytes32[] memory responseIds = new bytes32[](0);

        vm.prank(executor);
        vm.expectRevert(Errors.EmptyBatch.selector);
        responseCommitment.recordApplicationResponses(appIds, responseIds);
    }

    function test_recordApplicationResponses_arrayLengthMismatch_reverts() public {
        bytes32 appId1 = _submitApplication(applicant1);
        bytes32 appId2 = _submitApplication(applicant2);

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId1;
        appIds[1] = appId2;

        bytes32[] memory responseIds = new bytes32[](1);
        responseIds[0] = _generateResponseId(appId1);

        vm.prank(executor);
        vm.expectRevert(Errors.ArrayLengthMismatch.selector);
        responseCommitment.recordApplicationResponses(appIds, responseIds);
    }

    function test_recordApplicationResponses_applicationNotFound_reverts() public {
        bytes32 appId1 = _submitApplication(applicant1);
        bytes32 fakeAppId = keccak256("nonexistent");

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId1;
        appIds[1] = fakeAppId;

        bytes32[] memory responseIds = new bytes32[](2);
        responseIds[0] = _generateResponseId(appId1);
        responseIds[1] = _generateResponseId(fakeAppId);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApplicationNotFound.selector, fakeAppId));
        responseCommitment.recordApplicationResponses(appIds, responseIds);
    }

    function test_recordApplicationResponses_alreadyResponded_reverts() public {
        bytes32 appId1 = _submitApplication(applicant1);
        bytes32 appId2 = _submitApplication(applicant2);

        _respondToApplication(appId1);

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId1;
        appIds[1] = appId2;

        bytes32[] memory responseIds = new bytes32[](2);
        responseIds[0] = _generateResponseId(appId1);
        responseIds[1] = _generateResponseId(appId2);

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApplicationAlreadyResponded.selector, appId1));
        responseCommitment.recordApplicationResponses(appIds, responseIds);
    }

    function test_recordApplicationResponses_zeroApplicationId_revertsAtomically() public {
        bytes32 appId = _submitApplication(applicant1);
        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId;
        appIds[1] = bytes32(0);
        bytes32[] memory responseIds = new bytes32[](2);
        responseIds[0] = _generateResponseId(appId);
        responseIds[1] = keccak256("response");

        vm.prank(executor);
        vm.expectRevert(Errors.ZeroApplicationId.selector);
        responseCommitment.recordApplicationResponses(appIds, responseIds);

        assertFalse(responseCommitment.application(appId).isResponded);
    }

    function test_recordApplicationResponses_zeroResponseId_revertsAtomically() public {
        bytes32 appId1 = _submitApplication(applicant1);
        bytes32 appId2 = _submitApplication(applicant2);
        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId1;
        appIds[1] = appId2;
        bytes32[] memory responseIds = new bytes32[](2);
        responseIds[0] = _generateResponseId(appId1);
        responseIds[1] = bytes32(0);

        vm.prank(executor);
        vm.expectRevert(Errors.ZeroResponseId.selector);
        responseCommitment.recordApplicationResponses(appIds, responseIds);

        assertFalse(responseCommitment.application(appId1).isResponded);
        assertFalse(responseCommitment.application(appId2).isResponded);
    }

    function test_recordApplicationResponses_nonExecutor_reverts() public {
        bytes32 appId = _submitApplication(applicant1);

        bytes32[] memory appIds = new bytes32[](1);
        appIds[0] = appId;

        bytes32[] memory responseIds = new bytes32[](1);
        responseIds[0] = _generateResponseId(appId);

        vm.prank(employer);
        vm.expectRevert(Errors.NotExecutor.selector);
        responseCommitment.recordApplicationResponses(appIds, responseIds);
    }

    function test_recordApplicationResponses_executor_success() public {
        bytes32 appId1 = _submitApplication(applicant1);
        bytes32 appId2 = _submitApplication(applicant2);

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId1;
        appIds[1] = appId2;

        _batchRespondToApplicationsAs(appIds, executor);

        ApplicationView memory app1 = responseCommitment.application(appId1);
        ApplicationView memory app2 = responseCommitment.application(appId2);
        assertTrue(app1.isResponded);
        assertTrue(app2.isResponded);
    }

    function test_recordApplicationResponses_duplicateApplicationId_reverts() public {
        bytes32 appId = _submitApplication(applicant1);

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId;
        appIds[1] = appId;

        bytes32[] memory responseIds = new bytes32[](2);
        responseIds[0] = _generateResponseId(appId);
        responseIds[1] = keccak256("different-response");

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApplicationAlreadyResponded.selector, appId));
        responseCommitment.recordApplicationResponses(appIds, responseIds);
    }

    function test_recordApplicationResponses_whenPaused_allowed() public {
        bytes32 appId1 = _submitApplication(applicant1);
        bytes32 appId2 = _submitApplication(applicant2);

        vm.prank(owner);
        responseCommitment.pause();

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId1;
        appIds[1] = appId2;

        _batchRespondToApplications(appIds);

        _assertApplicationResponded(appId1);
        _assertApplicationResponded(appId2);
    }

    // ============ Batch Size Limit Tests ============

    function test_recordApplicationResponses_exactlyMaxBatchSize_succeeds() public {
        uint256 count = TEST_MAX_BATCH_SIZE;

        bytes32[] memory appIds = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            address applicantAddr = makeAddr(string(abi.encodePacked("applicant", i)));
            appIds[i] = _submitApplication(applicantAddr);
        }

        _batchRespondToApplications(appIds);

        for (uint256 i = 0; i < count; i++) {
            _assertApplicationResponded(appIds[i]);
        }
    }

    function test_recordApplicationResponses_exceedsMaxBatchSize_reverts() public {
        uint256 count = TEST_MAX_BATCH_SIZE + 1;

        bytes32[] memory appIds = new bytes32[](count);
        bytes32[] memory responseIds = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            address applicantAddr = makeAddr(string(abi.encodePacked("applicant", i)));
            appIds[i] = _submitApplication(applicantAddr);
            responseIds[i] = _generateResponseId(appIds[i]);
        }

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.BatchTooLarge.selector, count, TEST_MAX_BATCH_SIZE));
        responseCommitment.recordApplicationResponses(appIds, responseIds);
    }
}
