// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {
    IJobCommitment,
    JobView,
    ApplicationView,
    StakeReturnInfo,
    StakeReturnOutcome,
    StakeReturnStatus
} from "../../src/interfaces/IJobCommitment.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";
import {TEST_MAX_UNPUBLISHED_DURATION} from "../shared/TestBase.sol";

uint256 constant TEST_WITHDRAW_MAX_BATCH_SIZE = 50;

/// @title JobWithdrawalTest
/// @notice Tests for stake withdrawal and job expired settlement functionality
contract JobWithdrawalTest is JobCommitmentTestBase {
    // ============ Withdraw Applicant Stake Tests ============

    function test_withdraw_afterResponse() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        _respondToApplication(appId);

        uint256 applicantBalanceBefore = usdc.balanceOf(applicant1);

        vm.prank(applicant1);
        jobCommitment.withdrawStake(appId);

        assertEq(usdc.balanceOf(applicant1), applicantBalanceBefore + APPLICANT_STAKE);

        ApplicationView memory app = jobCommitment.application(appId);
        assertTrue(app.stakeWithdrawn);
    }

    function test_withdraw_afterDeadline() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        // Warp past deadline (3 days for tier 0)
        vm.warp(block.timestamp + 4 days);

        uint256 applicantBalanceBefore = usdc.balanceOf(applicant1);

        vm.prank(applicant1);
        jobCommitment.withdrawStake(appId);

        assertEq(usdc.balanceOf(applicant1), applicantBalanceBefore + APPLICANT_STAKE);
    }

    function test_withdraw_tooEarly_reverts() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        // Don't respond, don't wait for deadline

        vm.prank(applicant1);
        vm.expectRevert(Errors.WithdrawalNotReady.selector);
        jobCommitment.withdrawStake(appId);
    }

    function test_withdraw_applicationNotFound_reverts() public {
        bytes32 fakeAppId = keccak256("nonexistent");

        vm.prank(applicant1);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApplicationNotFound.selector, fakeAppId));
        jobCommitment.withdrawStake(fakeAppId);
    }

    function test_withdraw_alreadyWithdrawn_reverts() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        _respondToApplication(appId);

        vm.prank(applicant1);
        jobCommitment.withdrawStake(appId);

        vm.prank(applicant1);
        vm.expectRevert(Errors.StakeAlreadyWithdrawn.selector);
        jobCommitment.withdrawStake(appId);
    }

    function test_withdraw_afterJobClosed_success() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        _respondToApplication(appId);
        _unpublishJob(jobId);
        _closeJob(jobId, 1, 1, 1);

        uint256 balanceBefore = usdc.balanceOf(applicant1);
        vm.prank(applicant1);
        jobCommitment.withdrawStake(appId);

        assertEq(usdc.balanceOf(applicant1), balanceBefore + APPLICANT_STAKE);
    }

    function test_withdraw_nonApplicantExecutor_returnsToApplicant() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        _respondToApplication(appId);

        uint256 applicantBalanceBefore = usdc.balanceOf(applicant1);
        uint256 executorBalanceBefore = usdc.balanceOf(applicant2);

        vm.prank(applicant2);
        jobCommitment.withdrawStake(appId);

        assertEq(usdc.balanceOf(applicant1), applicantBalanceBefore + APPLICANT_STAKE);
        assertEq(usdc.balanceOf(applicant2), executorBalanceBefore);

        ApplicationView memory app = jobCommitment.application(appId);
        assertTrue(app.stakeWithdrawn);
    }

    function test_stakeReturnInfo_statuses() public {
        bytes32 fakeAppId = keccak256("missing");
        StakeReturnInfo memory missingInfo = jobCommitment.stakeReturnInfo(fakeAppId);
        assertEq(uint8(missingInfo.status), uint8(StakeReturnStatus.ApplicationNotFound));

        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        StakeReturnInfo memory notReadyInfo = jobCommitment.stakeReturnInfo(appId);
        assertEq(uint8(notReadyInfo.status), uint8(StakeReturnStatus.NotReady));
        assertEq(notReadyInfo.applicant, applicant1);
        assertEq(notReadyInfo.stake, APPLICANT_STAKE);
        assertFalse(notReadyInfo.isResponded);

        _respondToApplication(appId);

        StakeReturnInfo memory returnableInfo = jobCommitment.stakeReturnInfo(appId);
        assertEq(uint8(returnableInfo.status), uint8(StakeReturnStatus.Returnable));
        assertTrue(returnableInfo.isResponded);

        vm.prank(applicant2);
        jobCommitment.withdrawStake(appId);

        StakeReturnInfo memory withdrawnInfo = jobCommitment.stakeReturnInfo(appId);
        assertEq(uint8(withdrawnInfo.status), uint8(StakeReturnStatus.AlreadyWithdrawn));
    }

    function test_withdrawFunctionSelectors_matchConsumerAbi() public pure {
        assertEq(IJobCommitment.withdrawStake.selector, bytes4(keccak256("withdrawStake(bytes32)")));
        assertEq(IJobCommitment.withdrawStakes.selector, bytes4(keccak256("withdrawStakes(bytes32[])")));
        assertEq(IJobCommitment.stakeReturnInfo.selector, bytes4(keccak256("stakeReturnInfo(bytes32)")));
    }

    function test_withdrawStakes_returnsMultipleEligibleStakes() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        bytes32 appId2 = _applyToJob(jobId, applicant2);

        _respondToApplication(appId1);
        _respondToApplication(appId2);

        bytes32[] memory appIds = new bytes32[](2);
        appIds[0] = appId1;
        appIds[1] = appId2;

        uint256 applicant1BalanceBefore = usdc.balanceOf(applicant1);
        uint256 applicant2BalanceBefore = usdc.balanceOf(applicant2);

        vm.prank(makeAddr("stake-return-worker"));
        (uint16 returnedCount, uint16 skippedCount, uint256 totalReturned) = jobCommitment.withdrawStakes(appIds);

        assertEq(returnedCount, 2);
        assertEq(skippedCount, 0);
        assertEq(totalReturned, APPLICANT_STAKE * 2);
        assertEq(usdc.balanceOf(applicant1), applicant1BalanceBefore + APPLICANT_STAKE);
        assertEq(usdc.balanceOf(applicant2), applicant2BalanceBefore + APPLICANT_STAKE);
        assertEq(jobCommitment.totalApplicantStakes(), 0);
    }

    function test_withdrawStakes_skipsStaleIdsAndDuplicates() public {
        uint256 jobId = _publishJob(0);
        address applicant3 = makeAddr("batchApplicant3");
        _fundApplicant(applicant3);

        bytes32 readyAppId = _applyToJob(jobId, applicant1);
        bytes32 notReadyAppId = _applyToJob(jobId, applicant2);
        bytes32 withdrawnAppId = _applyToJob(jobId, applicant3);
        bytes32 missingAppId = keccak256("missing");

        _respondToApplication(readyAppId);
        _respondToApplication(withdrawnAppId);

        vm.prank(applicant3);
        jobCommitment.withdrawStake(withdrawnAppId);

        bytes32[] memory appIds = new bytes32[](5);
        appIds[0] = readyAppId;
        appIds[1] = notReadyAppId;
        appIds[2] = withdrawnAppId;
        appIds[3] = missingAppId;
        appIds[4] = readyAppId;

        uint256 applicant1BalanceBefore = usdc.balanceOf(applicant1);
        uint256 applicant2BalanceBefore = usdc.balanceOf(applicant2);
        uint256 applicant3BalanceBefore = usdc.balanceOf(applicant3);

        vm.prank(makeAddr("stake-return-worker"));
        (uint16 returnedCount, uint16 skippedCount, uint256 totalReturned) = jobCommitment.withdrawStakes(appIds);

        assertEq(returnedCount, 1);
        assertEq(skippedCount, 4);
        assertEq(totalReturned, APPLICANT_STAKE);
        assertEq(usdc.balanceOf(applicant1), applicant1BalanceBefore + APPLICANT_STAKE);
        assertEq(usdc.balanceOf(applicant2), applicant2BalanceBefore);
        assertEq(usdc.balanceOf(applicant3), applicant3BalanceBefore);
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE);
    }

    function test_withdrawStakes_emitsEveryOutcomeInInputOrder() public {
        uint256 jobId = _publishJob(0);
        bytes32 readyAppId = _applyToJob(jobId, applicant1);
        bytes32 notReadyAppId = _applyToJob(jobId, applicant2);
        bytes32 missingAppId = keccak256("missing");

        _respondToApplication(readyAppId);

        bytes32[] memory appIds = new bytes32[](4);
        appIds[0] = readyAppId;
        appIds[1] = notReadyAppId;
        appIds[2] = missingAppId;
        appIds[3] = readyAppId;

        vm.recordLogs();
        vm.prank(makeAddr("stake-return-worker"));
        jobCommitment.withdrawStakes(appIds);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 eventSig = keccak256("ApplicantStakeReturnProcessed(bytes32,address,uint256,uint8)");
        bytes32[4] memory expectedApplicationIds = [readyAppId, notReadyAppId, missingAppId, readyAppId];
        address[4] memory expectedApplicants = [applicant1, applicant2, address(0), applicant1];
        uint256[4] memory expectedAmounts = [APPLICANT_STAKE, APPLICANT_STAKE, uint256(0), APPLICANT_STAKE];
        StakeReturnOutcome[4] memory expectedOutcomes = [
            StakeReturnOutcome.Returned,
            StakeReturnOutcome.NotReady,
            StakeReturnOutcome.ApplicationNotFound,
            StakeReturnOutcome.AlreadyWithdrawn
        ];
        uint256 outcomeEvents = 0;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != eventSig) continue;

            assertEq(logs[i].topics[1], expectedApplicationIds[outcomeEvents]);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), expectedApplicants[outcomeEvents]);

            (uint256 amount, StakeReturnOutcome outcome) = abi.decode(logs[i].data, (uint256, StakeReturnOutcome));
            assertEq(amount, expectedAmounts[outcomeEvents]);
            assertEq(uint8(outcome), uint8(expectedOutcomes[outcomeEvents]));
            outcomeEvents++;
        }

        assertEq(outcomeEvents, appIds.length);
    }

    function test_withdrawStakes_exactlyMaxBatchSize_succeeds() public {
        uint256 jobId = _publishJob(0);
        bytes32[] memory appIds = new bytes32[](TEST_WITHDRAW_MAX_BATCH_SIZE);

        for (uint256 i = 0; i < TEST_WITHDRAW_MAX_BATCH_SIZE; i++) {
            address applicantAddr = makeAddr(string(abi.encodePacked("withdrawApplicant", i)));
            _fundApplicant(applicantAddr);
            appIds[i] = _applyToJob(jobId, applicantAddr);
        }

        _batchRespondToApplications(appIds);

        vm.prank(makeAddr("stake-return-worker"));
        (uint16 returnedCount, uint16 skippedCount, uint256 totalReturned) = jobCommitment.withdrawStakes(appIds);

        assertEq(returnedCount, TEST_WITHDRAW_MAX_BATCH_SIZE);
        assertEq(skippedCount, 0);
        assertEq(totalReturned, APPLICANT_STAKE * TEST_WITHDRAW_MAX_BATCH_SIZE);
        assertEq(jobCommitment.totalApplicantStakes(), 0);
    }

    function test_withdrawStakes_emptyBatch_reverts() public {
        bytes32[] memory appIds = new bytes32[](0);

        vm.expectRevert(Errors.EmptyBatch.selector);
        jobCommitment.withdrawStakes(appIds);
    }

    function test_withdrawStakes_exceedsMaxBatchSize_reverts() public {
        bytes32[] memory appIds = new bytes32[](TEST_WITHDRAW_MAX_BATCH_SIZE + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.BatchTooLarge.selector, TEST_WITHDRAW_MAX_BATCH_SIZE + 1, TEST_WITHDRAW_MAX_BATCH_SIZE
            )
        );
        jobCommitment.withdrawStakes(appIds);
    }

    function test_withdraw_transferFailure_revertsAndRollsBackAccounting() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        _respondToApplication(appId);

        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(IERC20.transfer.selector, applicant1, APPLICANT_STAKE),
            abi.encodeWithSignature("Error(string)", "TRANSFER_BLOCKED")
        );

        vm.prank(makeAddr("stake-return-worker"));
        vm.expectRevert(bytes("TRANSFER_BLOCKED"));
        jobCommitment.withdrawStake(appId);
        vm.clearMockedCalls();

        ApplicationView memory app = jobCommitment.application(appId);
        assertFalse(app.stakeWithdrawn);
        assertEq(jobCommitment.totalApplicantStakes(), APPLICANT_STAKE);
    }

    // ============ Expired Settlement Tests ============

    function test_settleExpiredJob_0percentResponse_100percentSlash() public {
        uint256 jobId = _publishJob(0);
        _applyToJob(jobId, applicant1);

        _unpublishJob(jobId);

        // Warp past expiration timeout (180 days from close)
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        // Only an executor can settle expired jobs, providing counters: 1 total, 0 responded, 0 on-time.
        _settleExpiredJob(jobId, 1, 0, 0);

        // 0% on-time response = 100% slash
        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - EMPLOYER_STAKE);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalanceBefore, EMPLOYER_STAKE, "Slash mismatch");
    }

    function test_settleExpiredJob_partialResponse_onTime() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        _applyToJob(jobId, applicant2);

        // Respond to only 1 of 2 applications on-time
        _respondToApplication(appId1);

        _unpublishJob(jobId);

        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _settleExpiredJob(jobId, 2, 1, 1);

        // 1 on-time out of 2 total = 50% on-time → 35% slash (harsh table, 3500 bps)
        uint256 expectedSlash = (EMPLOYER_STAKE * 3500) / 10_000;

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - expectedSlash);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleExpiredJob_nonZeroCountersRequireSnapshotRoot() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);
        _respondToApplication(appId);

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.CounterSnapshotRootRequired.selector), jobId, 1, 1, 1, bytes32(0), executor
        );
    }

    function test_settleExpiredJob_someOnTimeSomeMissing() public {
        uint256 jobId = _publishJob(0);

        // Create 10 applicants
        bytes32[] memory appIds = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            address app = makeAddr(string.concat("fw_app_", vm.toString(i)));
            _fundApplicant(app);
            appIds[i] = _applyToJob(jobId, app);
        }

        // Respond to 3 on-time, leave 7 unresponded
        for (uint256 i = 0; i < 3; i++) {
            _respondToApplication(appIds[i]);
        }

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _settleExpiredJob(jobId, 10, 3, 3);

        // 3 on-time out of 10 total = 30% → 50% slash (harsh table, 5000 bps for 1-49%)
        uint256 expectedSlash = (EMPLOYER_STAKE * 5000) / 10_000;

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - expectedSlash);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleExpiredJob_lateResponsesCountAsNotOnTime() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        bytes32 appId2 = _applyToJob(jobId, applicant2);

        // Respond to applicant1 on-time, applicant2 late
        _respondToApplication(appId1);
        _respondToApplicationLate(appId2);

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        // 2 total, 2 responded, 1 on-time
        _settleExpiredJob(jobId, 2, 2, 1);

        // All applications responded, so late responses use the soft table: 50% on-time → 22% slash.
        uint256 expectedSlash = (EMPLOYER_STAKE * 2200) / 10_000;

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - expectedSlash);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleExpiredJob_allRespondedAllLate_usesSoftSlash() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        bytes32 appId2 = _applyToJob(jobId, applicant2);

        _respondToApplicationLate(appId1);
        _respondToApplicationLate(appId2);

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _settleExpiredJob(jobId, 2, 2, 0);

        // All applications responded, so all-late expired settlement is soft max slash, not harsh zero-response slash.
        uint256 expectedSlash = (EMPLOYER_STAKE * 3000) / 10_000;

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - expectedSlash);
        _assertSlashBurned(burnAddressBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleExpiredJob_notExecutor_reverts() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);

        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        // Employer cannot settle expired jobs (only an executor can).
        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.NotExecutor.selector), jobId, 0, 0, 0, _counterSnapshotRoot(0), employer
        );
    }

    function test_settleExpiredJob_notExpired_reverts() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);

        // Don't warp - job not expired yet

        JobView memory job = jobCommitment.job(jobId);
        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(
                Errors.JobNotExpired.selector, job.unpublishedAt, TEST_MAX_UNPUBLISHED_DURATION, block.timestamp
            ),
            jobId,
            0,
            0,
            0,
            _counterSnapshotRoot(0),
            executor
        );
    }

    function test_settleExpiredJob_orgStakeAlreadySettled_reverts() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        // Record response and close the job to settle the org-side stake.
        _respondToApplication(appId);
        _unpublishJob(jobId);
        _closeJob(jobId, 1, 1, 1);

        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.OrgStakeAlreadySettled.selector, jobId),
            jobId,
            1,
            1,
            1,
            _counterSnapshotRoot(1),
            executor
        );
    }

    function test_settleExpiredJob_jobNotFound_reverts() public {
        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.JobNotFound.selector, 999), 999, 0, 0, 0, _counterSnapshotRoot(0), executor
        );
    }

    // ============ Counter Invariant Validation ============

    function test_settleExpiredJob_onTimeExceedsResponded_reverts() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        // onTime(5) > responded(3) — invalid
        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.InvalidCounters.selector, 10, 3, 5),
            jobId,
            10,
            3,
            5,
            _counterSnapshotRoot(10),
            executor
        );
    }

    function test_settleExpiredJob_respondedExceedsTotal_reverts() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        // responded(15) > total(10) — invalid
        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.InvalidCounters.selector, 10, 15, 5),
            jobId,
            10,
            15,
            5,
            _counterSnapshotRoot(10),
            executor
        );
    }

    // ============ Boundary Condition Tests ============

    function test_boundary_withdraw_exactlyAtDeadline() public {
        uint256 jobId = _publishJob(0);
        bytes32 appId = _applyToJob(jobId, applicant1);

        ApplicationView memory app = jobCommitment.application(appId);

        // Warp to exactly deadline (not past it)
        vm.warp(app.responseDeadline);

        // At deadline, should NOT be able to withdraw (need > deadline)
        vm.prank(applicant1);
        vm.expectRevert(Errors.WithdrawalNotReady.selector);
        jobCommitment.withdrawStake(appId);

        // 1 second later, should work
        vm.warp(app.responseDeadline + 1);
        vm.prank(applicant1);
        jobCommitment.withdrawStake(appId);
    }

    function test_boundary_settleExpiredJob_exactlyAtExpiration() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);

        JobView memory job = jobCommitment.job(jobId);
        uint256 expirationTime = job.unpublishedAt + TEST_MAX_UNPUBLISHED_DURATION;

        // Warp to exactly expiration
        vm.warp(expirationTime);

        // At exactly expiration, should work (< check, not <=)
        _settleExpiredJob(jobId);

        job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Closed));
    }

    function test_boundary_settleExpiredJob_oneSecondBeforeExpiration_reverts() public {
        uint256 jobId = _publishJob(0);

        _unpublishJob(jobId);

        JobView memory job = jobCommitment.job(jobId);
        uint256 expirationTime = job.unpublishedAt + TEST_MAX_UNPUBLISHED_DURATION;

        // Warp to 1 second before expiration
        vm.warp(expirationTime - 1);

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(
                Errors.JobNotExpired.selector, job.unpublishedAt, TEST_MAX_UNPUBLISHED_DURATION, expirationTime - 1
            ),
            jobId,
            0,
            0,
            0,
            _counterSnapshotRoot(0),
            executor
        );
    }
}
