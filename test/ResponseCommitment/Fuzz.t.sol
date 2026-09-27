// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {TEST_MIN_STAKE} from "../shared/TestBase.sol";

/// @title FuzzTest
/// @notice Fuzz tests for ResponseCommitment contract
contract FuzzTest is ResponseCommitmentTestBase {
    // ============ Create Commitment Fuzz Tests ============

    function testFuzz_activateCommitment_belowMinStake_reverts(uint256 stake) public {
        stake = bound(stake, 1, TEST_MIN_STAKE - 1);

        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signCommitmentActivation(DEFAULT_ORG_ID, stake, 0, keccak256("QmFuzz"), employer, keyNonce, expiry);
        uint256 expectedFee = _commitmentActivateFee(stake, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.StakeTooLow.selector, stake, TEST_MIN_STAKE));
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, stake, 0, expectedFee, keccak256("QmFuzz"), keyNonce, expiry, signature
        );
    }

    // ============ Fee Tier Fuzz Tests ============

    function testFuzz_feeTiers_invalid_reverts(uint8 feeTier) public {
        feeTier = uint8(bound(feeTier, 3, 255));

        uint256 keyNonce = _nextCommitmentActivationKeyNonce();
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signCommitmentActivation(
            DEFAULT_ORG_ID, EMPLOYER_STAKE, feeTier, keccak256("QmFuzz"), employer, keyNonce, expiry
        );
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidFeeTier.selector, feeTier));
        _executeCommitmentActivationWithFee(
            employer, DEFAULT_ORG_ID, EMPLOYER_STAKE, feeTier, 0, keccak256("QmFuzz"), keyNonce, expiry, signature
        );
    }
}
