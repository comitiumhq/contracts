// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {JobView} from "../../src/interfaces/IJobCommitment.sol";
import {JobExpiryStatus, JobStatus} from "../../src/types/JobTypes.sol";
import {TEST_MAX_UNPUBLISHED_DURATION, TEST_MAX_PUBLISHED_DURATION} from "../shared/TestBase.sol";

contract ExpiredSettlementTest is JobCommitmentTestBase {
    function test_settleExpiredJob_allOnTime_noSlash() public {
        uint256 jobId = _expiredUnpublishedJob();
        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnBalanceBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);

        _settleExpiredJob(jobId, 10, 10, 10);

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore);
        assertEq(usdc.balanceOf(SLASH_BURN_ADDRESS), burnBalanceBefore);
    }

    function test_settleExpiredJob_unanswered_usesHarshSlashing() public {
        uint256 jobId = _expiredUnpublishedJob();
        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnBalanceBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _settleExpiredJob(jobId, 10, 9, 9);

        uint256 expectedSlash = (EMPLOYER_STAKE * 500) / 10_000;
        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore - expectedSlash);
        _assertSlashBurned(burnBalanceBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleExpiredJob_allResponded_usesSoftSlashing() public {
        uint256 jobId = _expiredUnpublishedJob();
        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnBalanceBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _settleExpiredJob(jobId, 10, 10, 5);

        uint256 expectedSlash = (EMPLOYER_STAKE * 2200) / 10_000;
        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore - expectedSlash);
        _assertSlashBurned(burnBalanceBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleExpiredJob_zeroCounters_noSlash() public {
        uint256 jobId = _expiredUnpublishedJob();
        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _settleExpiredJob(jobId);

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore);
    }

    function test_settleExpiredJob_publishedJob_beforeExpiration_reverts() public {
        uint256 jobId = _publishJob(0);
        JobView memory job = jobCommitment.job(jobId);

        vm.warp(job.createdAt + TEST_MAX_PUBLISHED_DURATION - 1);

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(
                Errors.JobNotExpired.selector, job.createdAt, TEST_MAX_PUBLISHED_DURATION, block.timestamp
            ),
            jobId,
            0,
            0,
            0,
            bytes32(0),
            executor
        );
    }

    function test_settleExpiredJob_publishedJob_afterExpiration_succeeds() public {
        uint256 jobId = _publishJob(0);

        vm.warp(block.timestamp + TEST_MAX_PUBLISHED_DURATION + 1);

        (bool canSettle, JobExpiryStatus status) = jobCommitment.expiredSettlementInfo(jobId);
        assertTrue(canSettle);
        assertEq(uint8(status), uint8(JobExpiryStatus.Settleable));

        uint256 burnBalanceBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 jobFundsBalanceBefore = usdc.balanceOf(address(jobFunds));

        _settleExpiredJob(jobId, 1, 0, 0);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Closed));
        assertTrue(job.orgStakeSettled);
        _assertSlashBurned(burnBalanceBefore, feeRecipientBalanceBefore, job.stake, "Slash mismatch");
        assertEq(usdc.balanceOf(address(jobFunds)), jobFundsBalanceBefore - job.stake);
    }

    function test_settleExpiredJob_exactlyAtExpiration_succeeds() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);

        JobView memory job = jobCommitment.job(jobId);
        vm.warp(job.unpublishedAt + TEST_MAX_UNPUBLISHED_DURATION);

        _settleExpiredJob(jobId);

        assertEq(uint8(jobCommitment.job(jobId).status), uint8(JobStatus.Closed));
    }

    function test_expiredSettlementInfo_nonExistentJob() public view {
        (bool canSettle, JobExpiryStatus status) = jobCommitment.expiredSettlementInfo(999);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(JobExpiryStatus.JobNotFound));
    }

    function test_expiredSettlementInfo_closedJob() public {
        uint256 jobId = _publishJob(0);
        _closeJob(jobId);

        (bool canSettle, JobExpiryStatus status) = jobCommitment.expiredSettlementInfo(jobId);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(JobExpiryStatus.AlreadySettled));
    }

    function test_expiredSettlementInfo_unpublishedJobNotExpired() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);

        (bool canSettle, JobExpiryStatus status) = jobCommitment.expiredSettlementInfo(jobId);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(JobExpiryStatus.NotYetExpired));
    }

    function test_settleExpiredJob_nonExecutor_reverts() public {
        uint256 jobId = _expiredUnpublishedJob();

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.NotExecutor.selector), jobId, 0, 0, 0, bytes32(0), owner
        );
    }

    function _expiredUnpublishedJob() private returns (uint256 jobId) {
        jobId = _publishJob(0);
        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);
    }
}
