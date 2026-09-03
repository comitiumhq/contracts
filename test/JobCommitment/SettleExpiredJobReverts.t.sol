// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";

/// @title SettleExpiredJobRevertsTest
/// @notice Revert-branch coverage for settleExpiredJob that the happy-path settle helper cannot reach
///         (it always builds valid counters + a matching snapshot root).
contract SettleExpiredJobRevertsTest is JobCommitmentTestBase {
    function _expiredUnpublishedJob() internal returns (uint256 jobId) {
        jobId = _publishJob(0);
        _unpublishJob(jobId);
        _warpToExpiration(jobId);
    }

    function test_settleExpiredJob_revert_jobNotFound() public {
        uint256 bogusJobId = 999_999;
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(bogusJobId, 0, 0, 0, bytes32(0));

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.JobNotFound.selector, bogusJobId));
        jobCommitment.settleExpiredJob(bogusJobId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredJob_revert_alreadySettled() public {
        uint256 jobId = _expiredUnpublishedJob();
        _settleExpiredJob(jobId);
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(jobId, 0, 0, 0, bytes32(0));

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgStakeAlreadySettled.selector, jobId));
        jobCommitment.settleExpiredJob(jobId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredJob_revert_invalidCounters() public {
        uint256 jobId = _expiredUnpublishedJob();
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(1);
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(jobId, 1, 2, 0, counterSnapshotRoot);

        // respondedApplications (2) exceeds totalApplications (1) — structurally impossible.
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCounters.selector, uint32(1), uint32(2), uint32(0)));
        jobCommitment.settleExpiredJob(jobId, 1, 2, 0, counterSnapshotRoot, keyNonce, expiry, signature);
    }

    function test_settleExpiredJob_revert_counterSnapshotRootRequired() public {
        uint256 jobId = _expiredUnpublishedJob();
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(jobId, 1, 1, 1, bytes32(0));

        // totalApplications > 0 requires a non-zero snapshot root.
        vm.prank(executor);
        vm.expectRevert(Errors.CounterSnapshotRootRequired.selector);
        jobCommitment.settleExpiredJob(jobId, 1, 1, 1, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredJob_revert_tamperedCounters() public {
        uint256 jobId = _expiredUnpublishedJob();
        uint256 keyNonce = _nextExpiredSettlementKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(4);
        bytes memory signature = _signJobExpiredSettlement(jobId, 4, 4, 0, counterSnapshotRoot, keyNonce, expiry);

        vm.prank(executor);
        vm.expectRevert(Errors.InvalidSignature.selector);
        jobCommitment.settleExpiredJob(jobId, 4, 3, 0, counterSnapshotRoot, keyNonce, expiry, signature);
    }

    function test_settleExpiredJob_revert_expiredSignature() public {
        uint256 jobId = _expiredUnpublishedJob();
        uint256 keyNonce = _nextExpiredSettlementKeyNonce();
        uint256 expiry = vm.getBlockTimestamp() - 1;
        bytes memory signature = _signJobExpiredSettlement(jobId, 0, 0, 0, bytes32(0), keyNonce, expiry);

        vm.prank(executor);
        vm.expectRevert(Errors.SignatureExpired.selector);
        jobCommitment.settleExpiredJob(jobId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredJob_revert_wrongNonceScope() public {
        uint256 jobId = _expiredUnpublishedJob();
        uint256 keyNonce = _nextJobCloseKeyNonce();
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _signJobExpiredSettlement(jobId, 0, 0, 0, bytes32(0), keyNonce, expiry);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidNonceScope.selector, NONCE_SCOPE_JOB_CLOSE, NONCE_SCOPE_JOB_EXPIRED_SETTLEMENT
            )
        );
        jobCommitment.settleExpiredJob(jobId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredJob_consumesScopedNonce() public {
        uint256 jobId = _expiredUnpublishedJob();
        uint256 keyNonce = _nextExpiredSettlementKeyNonce();
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _signJobExpiredSettlement(jobId, 0, 0, 0, bytes32(0), keyNonce, expiry);

        vm.prank(executor);
        jobCommitment.settleExpiredJob(jobId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);

        assertEq(jobCommitment.nonces(operator, _authorizationKeyFromKeyNonce(keyNonce)), keyNonce + 1);
    }

    /// @notice The harsh/soft table boundary sits at respondedApplications == totalApplications. With identical
    ///         on-time counters, an unanswered application (responded < total) must slash strictly harder.
    function test_settleExpiredJob_harshVsSoftSlashBoundary() public {
        uint256 stake = EMPLOYER_STAKE;
        uint256 softSlash = _settleAndReadSlash(4);
        uint256 harshSlash = _settleAndReadSlash(3);

        assertEq(softSlash, stake * 3000 / 10000, "soft branch slash (3000 bps)");
        assertEq(harshSlash, stake, "harsh branch slash (full, 10000 bps)");
        assertGt(harshSlash, softSlash, "an unanswered application must slash strictly harder");
    }

    function _settleAndReadSlash(uint32 respondedApplications) private returns (uint256 slashAmount) {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        _warpToExpiration(jobId);
        uint256 burnBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);

        _settleExpiredJob(jobId, 4, respondedApplications, 0);

        return usdc.balanceOf(SLASH_BURN_ADDRESS) - burnBefore;
    }
}
