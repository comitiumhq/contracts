// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {CommitmentView} from "../../src/interfaces/IResponseCommitment.sol";
import {CommitmentStatus} from "../../src/types/CommitmentTypes.sol";
import {TEST_MIN_STAKE, TEST_MAX_STOPPED_DURATION} from "../shared/TestBase.sol";

contract PropertyFuzzTest is ResponseCommitmentTestBase {
    // ============ E2E Accounting Conservation ============

    function testFuzz_e2e_accounting_settleCommitment(uint256 stake, uint8 feeTier) public {
        stake = bound(stake, TEST_MIN_STAKE, 1_000_000_000_000); // up to 1M USDC
        feeTier = uint8(bound(feeTier, 0, 2));

        _fundOrg(DEFAULT_ORG_ID, employerPrivateKey, stake * 3);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 orgOpBalBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        uint256 commitmentId = _activateCommitmentWithParams(DEFAULT_ORG_ID, stake, feeTier, keccak256("QmAcc"));

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        uint256 fee = commitment.feeAmount;

        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId);

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBefore + fee, "Fee recipient must receive exactly fee");

        assertEq(
            _getOrgOperationalBalance(DEFAULT_ORG_ID), orgOpBalBefore - fee, "Org should get full stake back minus fee"
        );
    }

    function testFuzz_e2e_accounting_settleExpiredCommitment(
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
        uint256 commitmentId = _activateCommitmentWithParams(DEFAULT_ORG_ID, stake, 0, keccak256("QmForce"));
        uint256 fee = responseCommitment.commitment(commitmentId).feeAmount;

        _stopCommitment(commitmentId);
        vm.warp(block.timestamp + TEST_MAX_STOPPED_DURATION + 1);

        uint32 total = _toUint32(totalApplications);
        uint32 responded = _toUint32(respondedApplications);
        _settleExpiredCommitment(commitmentId, total, responded, responded);

        uint256 slashAmount = usdc.balanceOf(SLASH_BURN_ADDRESS) - burnBalanceBefore;
        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);

        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Settled));
        assertLe(slashAmount, stake);
        assertEq(_getOrgOperationalBalance(DEFAULT_ORG_ID), orgBalanceBefore - fee - slashAmount);
        assertEq(commitmentFunds.totalAccountedBalance(), usdc.balanceOf(address(commitmentFunds)));
    }

    // ============ State Machine: No Backward Transitions ============

    function test_settledCommitment_noBackwardTransition() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId);

        _assertCommitmentStatus(commitmentId, CommitmentStatus.Settled);

        {
            uint256 settleKeyNonce = _nextCommitmentStopKeyNonce();
            uint256 settleExpiry = block.timestamp + 1 hours;
            bytes memory settleSig = _signCommitmentStop(commitmentId, employer, settleKeyNonce, settleExpiry);
            vm.prank(employer);
            vm.expectRevert(
                abi.encodeWithSelector(
                    Errors.InvalidCommitmentStatus.selector, CommitmentStatus.Settled, CommitmentStatus.Active
                )
            );
            responseCommitment.stopCommitment(commitmentId, settleKeyNonce, settleExpiry, settleSig);
        }

        uint256 keyNonce = _nextCommitmentSettleKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory sig = _signCommitmentSettlement(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry);
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSelector(Errors.CommitmentAlreadySettled.selector, commitmentId));
        responseCommitment.settleCommitment(commitmentId, 0, 0, 0, _counterSnapshotRoot(0), keyNonce, expiry, sig);
    }
}
