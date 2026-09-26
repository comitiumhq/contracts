// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase, TEST_MAX_UNPUBLISHED_DURATION} from "../shared/TestBase.sol";
import {JobCommitment} from "../../src/JobCommitment.sol";
import {IJobFunds} from "../../src/interfaces/IJobFunds.sol";
import {Errors} from "../../src/Errors.sol";
import {FeeTier, JobConfig} from "../../src/types/ConfigTypes.sol";
import {JobExpiryStatus} from "../../src/types/JobTypes.sol";

contract JobCommitmentEdgeCasesTest is JobCommitmentTestBase {
    function test_constructor_zeroJobFunds_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new JobCommitment(
            IJobFunds(address(0)),
            owner,
            address(forwarder),
            operator,
            executor,
            _defaultJobConfig(),
            _defaultFeeTiers()
        );
    }

    function test_constructor_zeroOperator_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new JobCommitment(
            jobFunds, owner, address(forwarder), address(0), executor, _defaultJobConfig(), _defaultFeeTiers()
        );
    }

    function test_constructor_tierCountTiersLengthMismatch_reverts() public {
        JobConfig memory config = _defaultJobConfig();
        config.tierCount = 3;
        FeeTier[] memory tiers = _twoFeeTiers();

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        new JobCommitment(jobFunds, owner, address(forwarder), operator, executor, config, tiers);
    }

    function test_constructor_zeroExecutor_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new JobCommitment(
            jobFunds, owner, address(forwarder), operator, address(0), _defaultJobConfig(), _defaultFeeTiers()
        );
    }

    function test_constructor_overlappingRoles_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, operator));
        new JobCommitment(
            jobFunds, owner, address(forwarder), operator, operator, _defaultJobConfig(), _defaultFeeTiers()
        );
    }

    function test_constructor_trustedForwarderExecutor_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, address(forwarder)));
        new JobCommitment(
            jobFunds, owner, address(forwarder), operator, address(forwarder), _defaultJobConfig(), _defaultFeeTiers()
        );
    }

    function test_setJobConfig_tierCountTiersLengthMismatch_reverts() public {
        JobConfig memory config = _defaultJobConfig();
        config.tierCount = 3;
        FeeTier[] memory tiers = _twoFeeTiers();

        vm.prank(owner);
        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        jobCommitment.setJobConfig(config, tiers);
    }

    function test_currentJobConfig() public view {
        JobConfig memory config = jobCommitment.currentJobConfig();

        assertEq(config.minStake, 50_000_000);
        assertEq(config.tierCount, 3);
        assertEq(config.maxBatchSize, 50);

        assertEq(jobCommitment.feeTier(1, 0).baseFee, 25_000_000);
        assertEq(jobCommitment.feeTier(1, 1).baseFee, 35_000_000);
        assertEq(jobCommitment.feeTier(1, 2).baseFee, 50_000_000);
        assertEq(jobCommitment.feeTier(1, 0).feeBps, 150);
        assertEq(jobCommitment.feeTier(1, 1).feeBps, 250);
        assertEq(jobCommitment.feeTier(1, 2).feeBps, 350);
    }

    function test_expiredSettlementInfo_activeNotExpired() public {
        uint256 jobId = _publishJob(0);

        (bool canSettle, JobExpiryStatus status) = jobCommitment.expiredSettlementInfo(jobId);

        assertFalse(canSettle);
        assertEq(uint8(status), uint8(JobExpiryStatus.NotYetExpired));
    }

    function testFuzz_nonOwner_cannotPause(address caller) public {
        vm.assume(caller != owner);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        jobCommitment.pause();
    }

    function testFuzz_nonOwner_cannotAddOperator(address caller, address newOperator) public {
        vm.assume(caller != owner);
        vm.assume(newOperator != address(0));

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        jobCommitment.addOperator(newOperator);
    }

    function testFuzz_expiredSignature_publishJob(uint256 pastTime) public {
        pastTime = bound(pastTime, 1, block.timestamp);
        uint256 expiry = block.timestamp - pastTime;

        uint256 keyNonce = _nextJobPublishKeyNonce();
        bytes memory sig =
            _signJobPublish(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmExpired"), employer, keyNonce, expiry);
        uint256 expectedFee = _jobPublishFee(EMPLOYER_STAKE, 0);

        vm.expectRevert(Errors.SignatureExpired.selector);
        _executeJobPublishWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, expectedFee, keccak256("QmExpired"), keyNonce, expiry, sig
        );
    }

    function testFuzz_expiredSignature_submitApplication(uint256 pastTime) public {
        pastTime = bound(pastTime, 1, block.timestamp);
        uint256 expiry = block.timestamp - pastTime;

        bytes32 appId = keccak256("expired-app");
        bytes memory sig = _signApplication(appId, applicant1, 3, expiry);

        vm.prank(applicant1);
        vm.expectRevert(Errors.SignatureExpired.selector);
        jobCommitment.submitApplication(appId, 3, expiry, sig);
    }

    function testFuzz_nonExecutor_cannotSettleExpiredJob(address caller) public {
        vm.assume(caller != executor);
        vm.assume(caller != address(0));

        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        vm.warp(block.timestamp + TEST_MAX_UNPUBLISHED_DURATION + 1);

        _expectExpiredSettlementRevert(
            abi.encodeWithSelector(Errors.NotExecutor.selector), jobId, 0, 0, 0, _counterSnapshotRoot(0), caller
        );
    }

    function _twoFeeTiers() private pure returns (FeeTier[] memory tiers) {
        tiers = new FeeTier[](2);
        tiers[0] = FeeTier({baseFee: 25_000_000, feeBps: 150, deadlineDays: 3});
        tiers[1] = FeeTier({baseFee: 35_000_000, feeBps: 250, deadlineDays: 7});
    }
}
