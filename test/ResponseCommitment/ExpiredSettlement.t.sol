// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {CommitmentView} from "../../src/interfaces/IResponseCommitment.sol";
import {CommitmentExpiryStatus, CommitmentStatus} from "../../src/types/CommitmentTypes.sol";
import {TEST_MAX_STOPPED_DURATION, TEST_MAX_ACTIVE_DURATION} from "../shared/TestBase.sol";

contract ExpiredSettlementTest is ResponseCommitmentTestBase {
    function test_settleExpiredCommitment_allOnTime_noSlash() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnBalanceBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);

        _settleExpiredCommitment(commitmentId, 10, 10, 10);

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore);
        assertEq(usdc.balanceOf(SLASH_BURN_ADDRESS), burnBalanceBefore);
    }

    function test_settleExpiredCommitment_unanswered_usesHarshSlashing() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnBalanceBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _settleExpiredCommitment(commitmentId, 10, 9, 9);

        uint256 expectedSlash = (EMPLOYER_STAKE * 500) / 10_000;
        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore - expectedSlash);
        _assertSlashBurned(burnBalanceBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleExpiredCommitment_allResponded_usesSoftSlashing() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 burnBalanceBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        _settleExpiredCommitment(commitmentId, 10, 10, 5);

        uint256 expectedSlash = (EMPLOYER_STAKE * 2200) / 10_000;
        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore - expectedSlash);
        _assertSlashBurned(burnBalanceBefore, feeRecipientBalanceBefore, expectedSlash, "Slash mismatch");
    }

    function test_settleExpiredCommitment_zeroCounters_noSlash() public {
        uint256 commitmentId = _expiredStoppedCommitment();
        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _settleExpiredCommitment(commitmentId);

        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore);
    }

    function test_settleExpiredCommitment_activeCommitment_beforeExpiration_reverts() public {
        uint256 commitmentId = _activateCommitment(0);
        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);

        vm.warp(commitment.activatedAt + TEST_MAX_ACTIVE_DURATION - 1);

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(
                Errors.CommitmentNotExpired.selector, commitment.activatedAt, TEST_MAX_ACTIVE_DURATION, block.timestamp
            ),
            commitmentId,
            0,
            0,
            0,
            bytes32(0),
            executor
        );
    }

    function test_settleExpiredCommitment_activeCommitment_afterExpiration_succeeds() public {
        uint256 commitmentId = _activateCommitment(0);

        vm.warp(block.timestamp + TEST_MAX_ACTIVE_DURATION + 1);

        (bool canSettle, CommitmentExpiryStatus status) = responseCommitment.expiredSettlementInfo(commitmentId);
        assertTrue(canSettle);
        assertEq(uint8(status), uint8(CommitmentExpiryStatus.Settleable));

        uint256 burnBalanceBefore = usdc.balanceOf(SLASH_BURN_ADDRESS);
        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);
        uint256 commitmentFundsBalanceBefore = usdc.balanceOf(address(commitmentFunds));

        _settleExpiredCommitment(commitmentId, 1, 0, 0);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Settled));
        _assertSlashBurned(burnBalanceBefore, feeRecipientBalanceBefore, commitment.stake, "Slash mismatch");
        assertEq(usdc.balanceOf(address(commitmentFunds)), commitmentFundsBalanceBefore - commitment.stake);
    }

    function test_settleExpiredCommitment_exactlyAtExpiration_succeeds() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        vm.warp(commitment.stoppedAt + TEST_MAX_STOPPED_DURATION);

        _settleExpiredCommitment(commitmentId);

        assertEq(uint8(responseCommitment.commitment(commitmentId).status), uint8(CommitmentStatus.Settled));
    }

    function test_expiredSettlementInfo_nonExistentCommitment() public view {
        (bool canSettle, CommitmentExpiryStatus status) = responseCommitment.expiredSettlementInfo(999);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(CommitmentExpiryStatus.CommitmentNotFound));
    }

    function test_expiredSettlementInfo_settledCommitment() public {
        uint256 commitmentId = _activateCommitment(0);
        _settleCommitment(commitmentId);

        (bool canSettle, CommitmentExpiryStatus status) = responseCommitment.expiredSettlementInfo(commitmentId);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(CommitmentExpiryStatus.AlreadySettled));
    }

    function test_expiredSettlementInfo_stoppedCommitmentNotExpired() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);

        (bool canSettle, CommitmentExpiryStatus status) = responseCommitment.expiredSettlementInfo(commitmentId);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(CommitmentExpiryStatus.NotYetExpired));
    }

    function test_settleExpiredCommitment_nonExecutor_reverts() public {
        uint256 commitmentId = _expiredStoppedCommitment();

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.NotExecutor.selector), commitmentId, 0, 0, 0, bytes32(0), owner
        );
    }
}
