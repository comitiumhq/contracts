// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase, TEST_MAX_ACTIVE_DURATION, TEST_MAX_STOPPED_DURATION} from "../shared/TestBase.sol";
import {ApplicationView, CommitmentView} from "../../src/interfaces/IResponseCommitment.sol";
import {CommitmentStatus} from "../../src/types/CommitmentTypes.sol";

contract StateImmutabilityTest is ResponseCommitmentTestBase {
    function testFuzz_applicationFields_immutableAfterRespond(uint8 numApps) public {
        numApps = uint8(bound(numApps, 1, 5));

        bytes32[] memory appIds = new bytes32[](numApps);
        for (uint8 i = 0; i < numApps; i++) {
            address app = makeAddr(string(abi.encodePacked("immut", i)));
            appIds[i] = _submitApplication(app);
        }

        for (uint8 i = 0; i < numApps; i++) {
            ApplicationView memory before = responseCommitment.application(appIds[i]);
            assertFalse(before.isResponded, "Should be false before respond");

            _respondToApplication(appIds[i]);

            ApplicationView memory after_ = responseCommitment.application(appIds[i]);
            assertTrue(after_.isResponded, "Should be true after respond");

            assertEq(after_.applicant, before.applicant, "applicant must not change");
            assertEq(after_.appliedAt, before.appliedAt, "appliedAt must not change");
            assertEq(after_.responseDeadline, before.responseDeadline, "responseDeadline must not change");
        }
    }

    function test_commitmentTimestamps_statusConsistency() public {
        uint256 commitmentId = _activateCommitment(0);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(commitment.stoppedAt, 0, "stoppedAt must be 0 when Active");
        assertEq(commitment.settledAt, 0, "settledAt must be 0 when Active");

        _stopCommitment(commitmentId);

        commitment = responseCommitment.commitment(commitmentId);
        assertGt(commitment.stoppedAt, 0, "stoppedAt must be set when Stopped");
        assertEq(commitment.settledAt, 0, "settledAt must be 0 when Stopped");

        uint256 stoppedAtBefore = commitment.stoppedAt;
        _settleCommitment(commitmentId);

        commitment = responseCommitment.commitment(commitmentId);
        assertGt(commitment.stoppedAt, 0, "stoppedAt must remain set when Settled");
        assertGt(commitment.settledAt, 0, "settledAt must be set when Settled");
        assertEq(commitment.stoppedAt, stoppedAtBefore, "stoppedAt must not change after settle");
    }

    function test_normalSettle_recordsDistinctLifecycleTimestamps() public {
        uint256 commitmentId = _activateCommitment(0);

        _stopCommitment(commitmentId);
        vm.warp(block.timestamp + 1);
        _settleCommitment(commitmentId);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertGt(commitment.stoppedAt, 0, "stoppedAt must be set");
        assertGt(commitment.settledAt, commitment.stoppedAt, "settledAt must follow stoppedAt");
    }

    function test_normalSettleFromActive_leavesStoppedTimestampUnset() public {
        uint256 commitmentId = _activateCommitment(0);

        _settleCommitment(commitmentId);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(commitment.stoppedAt, 0, "direct settle must not fabricate a stop boundary");
        assertGt(commitment.settledAt, 0, "settledAt must be set");
    }

    function test_expiredSettlementFromActive_recordsBothTimestamps() public {
        uint256 commitmentId = _activateCommitment(0);

        vm.warp(block.timestamp + TEST_MAX_ACTIVE_DURATION + 1);
        _settleExpiredCommitment(commitmentId);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Settled));
        assertGt(commitment.stoppedAt, 0, "expired settlement must record stop");
        assertGt(commitment.settledAt, 0, "expired settlement must record settle");
        assertEq(commitment.stoppedAt, commitment.settledAt, "forced stop and settle share the settlement timestamp");
    }

    function test_stoppedAt_immutable_settleExpiredCommitment() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        uint256 stoppedAtFirst = commitment.stoppedAt;
        assertGt(stoppedAtFirst, 0, "stoppedAt must be set after stop");

        vm.warp(commitment.stoppedAt + TEST_MAX_STOPPED_DURATION + 1);
        _settleExpiredCommitment(commitmentId);

        commitment = responseCommitment.commitment(commitmentId);
        assertEq(commitment.stoppedAt, stoppedAtFirst, "stoppedAt must not change after expired settlement");
    }
}
