// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";

/// @title SettleExpiredCommitmentRevertsTest
/// @notice Revert-branch coverage for settleExpiredCommitment that the happy-path settle helper cannot reach
///         (it always builds valid counters + a matching snapshot root).
contract SettleExpiredCommitmentRevertsTest is ResponseCommitmentTestBase {
    function test_settleExpiredCommitment_revert_commitmentNotFound() public {
        uint256 bogusCommitmentId = 999_999;
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(bogusCommitmentId, 0, 0, 0, bytes32(0));

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentNotFound.selector, bogusCommitmentId));
        responseCommitment.settleExpiredCommitment(bogusCommitmentId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredCommitment_revert_alreadySettled() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        _settleExpiredCommitment(commitmentId);
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(commitmentId, 0, 0, 0, bytes32(0));

        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentAlreadySettled.selector, commitmentId));
        responseCommitment.settleExpiredCommitment(commitmentId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredCommitment_revert_invalidCounters() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(1);
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(commitmentId, 1, 2, 0, counterSnapshotRoot);

        // respondedApplications (2) exceeds totalApplications (1) — structurally impossible.
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidCounters.selector, uint32(1), uint32(2), uint32(0)));
        responseCommitment.settleExpiredCommitment(
            commitmentId, 1, 2, 0, counterSnapshotRoot, keyNonce, expiry, signature
        );
    }

    function test_settleExpiredCommitment_revert_counterSnapshotRootRequired() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        (uint256 keyNonce, uint256 expiry, bytes memory signature) =
            _expiredSettlementAuthorization(commitmentId, 1, 1, 1, bytes32(0));

        // totalApplications > 0 requires a non-zero snapshot root.
        vm.prank(executor);
        vm.expectRevert(Errors.CounterSnapshotRootRequired.selector);
        responseCommitment.settleExpiredCommitment(commitmentId, 1, 1, 1, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredCommitment_revert_tamperedCounters() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        uint256 keyNonce = _nextExpiredSettlementKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes32 counterSnapshotRoot = _counterSnapshotRoot(4);
        bytes memory signature =
            _signExpiredCommitmentSettlement(commitmentId, 4, 4, 0, counterSnapshotRoot, keyNonce, expiry);

        vm.prank(executor);
        vm.expectRevert(Errors.InvalidSignature.selector);
        responseCommitment.settleExpiredCommitment(
            commitmentId, 4, 3, 0, counterSnapshotRoot, keyNonce, expiry, signature
        );
    }

    function test_settleExpiredCommitment_revert_expiredSignature() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        uint256 keyNonce = _nextExpiredSettlementKeyNonce();
        uint256 expiry = vm.getBlockTimestamp() - 1;
        bytes memory signature = _signExpiredCommitmentSettlement(commitmentId, 0, 0, 0, bytes32(0), keyNonce, expiry);

        vm.prank(executor);
        vm.expectRevert(Errors.SignatureExpired.selector);
        responseCommitment.settleExpiredCommitment(commitmentId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredCommitment_revert_wrongNonceScope() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _signExpiredCommitmentSettlement(commitmentId, 0, 0, 0, bytes32(0), keyNonce, expiry);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.InvalidNonceScope.selector,
                NONCE_SCOPE_COMMITMENT_SETTLEMENT,
                NONCE_SCOPE_EXPIRED_COMMITMENT_SETTLEMENT
            )
        );
        responseCommitment.settleExpiredCommitment(commitmentId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);
    }

    function test_settleExpiredCommitment_consumesScopedNonce() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        uint256 keyNonce = _nextExpiredSettlementKeyNonce();
        uint256 expiry = vm.getBlockTimestamp() + 1 hours;
        bytes memory signature = _signExpiredCommitmentSettlement(commitmentId, 0, 0, 0, bytes32(0), keyNonce, expiry);

        vm.prank(executor);
        responseCommitment.settleExpiredCommitment(commitmentId, 0, 0, 0, bytes32(0), keyNonce, expiry, signature);

        assertEq(responseCommitment.nonces(operator, _authorizationKeyFromKeyNonce(keyNonce)), keyNonce + 1);
    }

    /// @notice The harsh/soft table boundary sits at respondedApplications == totalApplications. With identical
    ///         on-time counters, an unanswered application (responded < total) must slash strictly harder.
    function test_settleExpiredCommitment_harshVsSoftSlashBoundary() public {
        uint256 stake = EMPLOYER_STAKE;
        uint256 softSlash = _settleAndReadSlash(4);
        uint256 harshSlash = _settleAndReadSlash(3);

        assertEq(softSlash, stake * 3000 / 10000, "soft branch slash (3000 bps)");
        assertEq(harshSlash, stake, "harsh branch slash (full, 10000 bps)");
        assertGt(harshSlash, softSlash, "an unanswered application must slash strictly harder");
    }

    function _settleAndReadSlash(uint32 respondedApplications) private returns (uint256 slashAmount) {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        _warpToExpiration(commitmentId);
        uint256 burnBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);

        _settleExpiredCommitment(commitmentId, 4, respondedApplications, 0);

        return usdc.balanceOf(SLASH_BURN_ADDRESS) - burnBefore;
    }
}
