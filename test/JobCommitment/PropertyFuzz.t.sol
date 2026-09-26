// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {JobView} from "../../src/interfaces/IJobCommitment.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";
import {TEST_MIN_STAKE, TEST_MAX_UNPUBLISHED_DURATION} from "../shared/TestBase.sol";

contract PropertyFuzzTest is JobCommitmentTestBase {
    // ============ E2E Accounting Conservation ============

    function testFuzz_e2e_accounting_closeJob(uint256 stake, uint8 feeTier) public {
        stake = bound(stake, TEST_MIN_STAKE, 1_000_000_000_000); // up to 1M USDC
        feeTier = uint8(bound(feeTier, 0, 2));

        _fundOrg(DEFAULT_ORG_ID, employerPrivateKey, stake * 3);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        uint256 jobId = _publishJobWithParams(DEFAULT_ORG_ID, stake, feeTier, keccak256("QmAcc"));

        JobView memory job = jobCommitment.job(jobId);
        uint256 fee = job.feeAmount;

        _unpublishJob(jobId);
        _closeJob(jobId);

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore + fee, "Fee recipient must receive exactly fee");

        assertEq(
            _getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - fee, "Org should get full stake back minus fee"
        );
    }

    function testFuzz_e2e_accounting_settleExpiredJob(
        uint256 stake,
        uint8 totalApplications,
        uint8 respondedApplications
    ) public {
        stake = bound(stake, TEST_MIN_STAKE, 1_000_000_000_000);
        totalApplications = uint8(bound(totalApplications, 1, 5));
        respondedApplications = uint8(bound(respondedApplications, 0, totalApplications));

        _fundOrg(DEFAULT_ORG_ID, employerPrivateKey, stake * 3);

        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnBalanceBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 jobId = _publishJobWithParams(DEFAULT_ORG_ID, stake, 0, keccak256("QmForce"));
        uint256 fee = jobCommitment.job(jobId).feeAmount;

        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        uint32 total = _toUint32(totalApplications);
        uint32 responded = _toUint32(respondedApplications);
        _settleExpiredJob(jobId, total, responded, responded);

        uint256 slashAmount = usdc.balanceOf(SLASH_BURN_ADDRESS) - burnBalanceBefore;
        JobView memory job = jobCommitment.job(jobId);

        assertEq(uint8(job.status), uint8(JobStatus.Closed));
        assertTrue(job.orgStakeSettled);
        assertLe(slashAmount, stake);
        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore - fee - slashAmount);
        assertEq(jobFunds.totalAccountedBalance(), usdc.balanceOf(address(jobFunds)));
    }

    // ============ State Machine: No Backward Transitions ============

    function test_closedJob_noBackwardTransition() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        _closeJob(jobId);

        _assertJobStatus(jobId, JobStatus.Closed);

        {
            uint256 closeKeyNonce = _nextJobUnpublishKeyNonce();
            uint256 closeExpiry = block.timestamp + 1 hours;
            bytes memory closeSig = _signJobUnpublish(jobId, employer, closeKeyNonce, closeExpiry);
            vm.prank(employer);
            vm.expectRevert(
                abi.encodeWithSelector(Errors.InvalidJobStatus.selector, JobStatus.Closed, JobStatus.Published)
            );
            jobCommitment.unpublishJob(jobId, closeKeyNonce, closeExpiry, closeSig);
        }

        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signJobClose(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobAlreadyClosed.selector, jobId));
        jobCommitment.closeJob(jobId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }
}
