// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {JobView, ApplicationView} from "../../src/interfaces/IJobCommitment.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";
import {TEST_TIER_0_BASE_FEE, TEST_MAX_UNPUBLISHED_DURATION} from "../shared/TestBase.sol";

/// @title IntegrationTest
/// @notice Integration tests for full job lifecycle scenarios
contract IntegrationTest is JobCommitmentTestBase {
    // ============ Full Lifecycle Tests ============

    function test_fullFlow_createApplyRespondUnpublishCloseWithdraw() public {
        uint256 applicant1Initial = usdc.balanceOf(applicant1);
        uint256 applicant2Initial = usdc.balanceOf(applicant2);
        uint256 feeRecipientInitial = usdc.balanceOf(feeRecipient);

        // 1. Create job
        uint256 jobId = _publishJobWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmIntegrationTest");

        uint256 fee = TEST_TIER_0_BASE_FEE + ((EMPLOYER_STAKE * 150) / 10_000);
        assertEq(usdc.balanceOf(feeRecipient), feeRecipientInitial + fee);

        // 2. Apply (2 applicants)
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        bytes32 appId2 = _applyToJob(jobId, applicant2);

        assertEq(usdc.balanceOf(applicant1), applicant1Initial - APPLICANT_STAKE);
        assertEq(usdc.balanceOf(applicant2), applicant2Initial - APPLICANT_STAKE);

        // 3. Respond to all
        _respondToApplication(appId1);
        _respondToApplication(appId2);

        // 4. Close job with operator-attested counters
        uint256 orgOpBalBeforeComplete = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        _unpublishJob(jobId);
        _closeJob(jobId, 2, 2, 2);

        // 0% slash for 100% on-time response
        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBeforeComplete);

        // 5. Applicants withdraw stakes
        _withdrawStake(appId1, applicant1);
        _withdrawStake(appId2, applicant2);

        // Applicants back to initial balance
        assertEq(usdc.balanceOf(applicant1), applicant1Initial);
        assertEq(usdc.balanceOf(applicant2), applicant2Initial);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Closed));
        assertTrue(job.orgStakeSettled);
    }

    function test_fullFlow_partialResponse_settleExpiredJob() public {
        // 1. Create job (tier 1 = 2.5% fee)
        uint256 jobId = _publishJobWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 1, "QmPartialTest");

        // 2. Apply (2 applicants)
        bytes32 appId1 = _applyToJob(jobId, applicant1);
        bytes32 appId2 = _applyToJob(jobId, applicant2);

        // 3. Respond to only 1 on time (50% on-time response rate)
        _respondToApplication(appId1);

        // 4. Close job (employer abandons)
        _unpublishJob(jobId);

        // 5. Wait for expiration and settle
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);

        // Operator attests counters: 2 total, 1 responded, 1 on-time.
        _settleExpiredJob(jobId, 2, 1, 1);

        // 50% on-time = 35% slash
        uint256 slashAmount = (EMPLOYER_STAKE * 3500) / 10_000;

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - slashAmount);
        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, slashAmount, "Slash mismatch");

        // 6. Applicants can still withdraw
        uint256 app1Before = usdc.balanceOf(applicant1);
        uint256 app2Before = usdc.balanceOf(applicant2);

        _withdrawStake(appId1, applicant1);
        _withdrawStake(appId2, applicant2);

        assertEq(usdc.balanceOf(applicant1), app1Before + APPLICANT_STAKE);
        assertEq(usdc.balanceOf(applicant2), app2Before + APPLICANT_STAKE);
    }

    // ============ Multi-Applicant Scenarios ============

    function test_multiApplicant_10applicants_allResponded() public {
        uint256 jobId = _publishJob(0);

        bytes32[] memory appIds = new bytes32[](10);
        for (uint256 i = 0; i < 10; i++) {
            address applicant = makeAddr(string(abi.encodePacked("applicant", i)));
            _fundApplicant(applicant);
            appIds[i] = _applyToJob(jobId, applicant);
        }

        for (uint256 i = 0; i < 10; i++) {
            _respondToApplication(appIds[i]);
        }

        // Close job - 0% slash for 100% on-time
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        _unpublishJob(jobId);
        _closeJob(jobId, 10, 10, 10);

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore);

        for (uint256 i = 0; i < 10; i++) {
            address applicant = makeAddr(string(abi.encodePacked("applicant", i)));
            uint256 balanceBefore = usdc.balanceOf(applicant);
            _withdrawStake(appIds[i], applicant);
            assertEq(usdc.balanceOf(applicant), balanceBefore + APPLICANT_STAKE);
        }
    }

    function test_multiApplicant_10applicants_partialResponse_settleExpiredJob() public {
        uint256 jobId = _publishJob(0);

        bytes32[] memory appIds = new bytes32[](10);
        address[] memory applicants = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            applicants[i] = makeAddr(string(abi.encodePacked("applicant", i)));
            _fundApplicant(applicants[i]);
            appIds[i] = _applyToJob(jobId, applicants[i]);
        }

        // Respond to only 3 on time (30% on-time response rate -> 50% slash)
        for (uint256 i = 0; i < 3; i++) {
            _respondToApplication(appIds[i]);
        }

        _unpublishJob(jobId);

        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint256 burnAddressBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _settleExpiredJob(jobId, 10, 3, 3);

        // 30% on-time response = 50% slash (worst tier)
        uint256 expectedSlash = EMPLOYER_STAKE / 2;

        _assertSlashBurned(burnAddressBefore, feeRecipientBefore, expectedSlash, "Slash mismatch");
        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - expectedSlash);

        for (uint256 i = 0; i < 10; i++) {
            uint256 balanceBefore = usdc.balanceOf(applicants[i]);
            // Unresponded applicants wait for deadline; expired settlement does not change withdrawal readiness
            // They can withdraw after response deadline passes
            ApplicationView memory app = jobCommitment.application(appIds[i]);
            if (!app.isResponded && block.timestamp <= app.responseDeadline) vm.warp(app.responseDeadline + 1);
            _withdrawStake(appIds[i], applicants[i]);
            assertEq(usdc.balanceOf(applicants[i]), balanceBefore + APPLICANT_STAKE);
        }
    }

    function test_multiApplicant_someWithdrawBeforeResponse() public {
        uint256 jobId = _publishJob(0);

        bytes32[] memory appIds = new bytes32[](5);
        address[] memory applicants = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            applicants[i] = makeAddr(string(abi.encodePacked("applicant", i)));
            _fundApplicant(applicants[i]);
            appIds[i] = _applyToJob(jobId, applicants[i]);
        }

        // Respond to first 3
        for (uint256 i = 0; i < 3; i++) {
            _respondToApplication(appIds[i]);
        }

        // First 3 withdraw immediately
        for (uint256 i = 0; i < 3; i++) {
            _withdrawStake(appIds[i], applicants[i]);
        }

        // Respond to remaining 2
        for (uint256 i = 3; i < 5; i++) {
            _respondToApplication(appIds[i]);
        }

        _unpublishJob(jobId);
        _closeJob(jobId, 5, 5, 5);

        // Remaining 2 withdraw
        for (uint256 i = 3; i < 5; i++) {
            _withdrawStake(appIds[i], applicants[i]);
        }

        for (uint256 i = 0; i < 5; i++) {
            assertEq(usdc.balanceOf(applicants[i]), 100_000_000, "applicant fully refunded after on-time response");
        }
    }

    function test_multiApplicant_updatedAmounts_areStoredPerApplication() public {
        _publishJob(0);

        bytes32 oldAmountApp = _applyToJobWithStake(applicant1, APPLICANT_STAKE);

        vm.prank(owner);
        jobCommitment.setApplicantStakeAmount(7_000_000);

        bytes32 newAmountApp = _applyToJobWithStake(applicant2, 7_000_000);

        assertEq(jobCommitment.application(oldAmountApp).stake, APPLICANT_STAKE);
        assertEq(jobCommitment.application(newAmountApp).stake, 7_000_000);
    }
}
