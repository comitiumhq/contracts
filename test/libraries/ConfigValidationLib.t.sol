// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ConfigValidationLib} from "../../src/libraries/ConfigValidationLib.sol";
import {FeeTier, CommitmentConfig, SlashingTable} from "../../src/types/ConfigTypes.sol";
import {Errors} from "../../src/Errors.sol";

contract ConfigValidationLibHarness {
    function validateCommitmentConfig(CommitmentConfig memory c) external pure {
        ConfigValidationLib.validateCommitmentConfig(c);
    }

    function validateFeeTiers(FeeTier[] memory tiers) external pure {
        ConfigValidationLib.validateFeeTiers(tiers);
    }
}

contract ConfigValidationLibTest is Test {
    using SafeCast for uint256;

    ConfigValidationLibHarness private harness;

    function setUp() public {
        harness = new ConfigValidationLibHarness();
    }

    function _validConfig() internal pure returns (CommitmentConfig memory) {
        return CommitmentConfig({
            minStake: 50_000_000,
            tierCount: 3,
            maxBatchSize: 50,
            maxStoppedDuration: uint32(90 days),
            maxActiveDuration: uint32(365 days),
            harshSlashing: SlashingTable(10000, 5000, 3500, 2500, 1800, 1000, 500, 200),
            softSlashing: SlashingTable(3000, 2500, 2200, 1800, 1200, 800, 500, 200)
        });
    }

    function _validFeeTiers(uint256 count) internal pure returns (FeeTier[] memory tiers) {
        tiers = new FeeTier[](count);

        for (uint256 i = 0; i < count; i++) {
            tiers[i] = FeeTier({
                baseFee: (25_000_000 + (i * 1_000_000)).toUint96(),
                feeBps: (100 + (i * 40)).toUint16(),
                deadlineDays: (3 + i).toUint8()
            });
        }
    }

    function test_validateCommitmentConfig_acceptsDefault() public view {
        harness.validateCommitmentConfig(_validConfig());
    }

    function test_validateFeeTiers_acceptsSupportedCounts() public view {
        harness.validateFeeTiers(_validFeeTiers(1));
        harness.validateFeeTiers(_validFeeTiers(3));
        harness.validateFeeTiers(_validFeeTiers(10));
    }

    function test_revert_feeTiersEmpty() public {
        FeeTier[] memory tiers = new FeeTier[](0);

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateFeeTiers(tiers);
    }

    function test_revert_feeTiersTooMany() public {
        FeeTier[] memory tiers = _validFeeTiers(11);

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateFeeTiers(tiers);
    }

    function testFuzz_validateFeeTiers_acceptsOrdered(
        uint8 countRaw,
        uint96 startBaseRaw,
        uint96 baseStepRaw,
        uint16 startFeeRaw,
        uint16 feeStepRaw,
        uint8 startDeadlineRaw,
        uint8 deadlineStepRaw
    ) public {
        uint256 count = bound(countRaw, 2, 10);
        uint256 maxBaseStep = 250_000_000 / (count - 1);
        uint96 baseStep = bound(baseStepRaw, 1, maxBaseStep).toUint96();
        uint96 startBase = bound(startBaseRaw, 0, 250_000_000 - (uint256(baseStep) * (count - 1))).toUint96();
        uint256 maxFeeStep = (500 - 100) / (count - 1);
        uint16 feeStep = bound(feeStepRaw, 0, maxFeeStep).toUint16();
        uint16 startFee = bound(startFeeRaw, 100, 500 - (uint256(feeStep) * (count - 1))).toUint16();
        uint256 maxDeadlineStep = (30 - 1) / (count - 1);
        uint8 deadlineStep = bound(deadlineStepRaw, 1, maxDeadlineStep).toUint8();
        uint8 startDeadline = bound(startDeadlineRaw, 1, 30 - (uint256(deadlineStep) * (count - 1))).toUint8();

        FeeTier[] memory tiers = new FeeTier[](count);
        for (uint256 i = 0; i < count; i++) {
            tiers[i] = FeeTier({
                baseFee: (uint256(startBase) + (uint256(baseStep) * i)).toUint96(),
                feeBps: (uint256(startFee) + (uint256(feeStep) * i)).toUint16(),
                deadlineDays: (uint256(startDeadline) + (uint256(deadlineStep) * i)).toUint8()
            });
        }

        harness.validateFeeTiers(tiers);
    }

    function testFuzz_validateFeeTiers_rejectsFeeOrdering(uint8 countRaw) public {
        uint256 count = bound(countRaw, 2, 10);
        FeeTier[] memory tiers = _validFeeTiers(count);
        tiers[0].feeBps = 200;
        tiers[1].feeBps = 199;

        vm.expectRevert(Errors.InvalidTierOrdering.selector);
        harness.validateFeeTiers(tiers);
    }

    function testFuzz_validateFeeTiers_rejectsDeadlineOrdering(uint8 countRaw) public {
        uint256 count = bound(countRaw, 2, 10);
        FeeTier[] memory tiers = _validFeeTiers(count);
        tiers[1].deadlineDays = tiers[0].deadlineDays;

        vm.expectRevert(Errors.InvalidTierOrdering.selector);
        harness.validateFeeTiers(tiers);
    }

    function test_revert_minStakeTooLow() public {
        CommitmentConfig memory c = _validConfig();
        c.minStake = 49_999_999;

        vm.expectPartialRevert(Errors.ConfigValueTooLow.selector);
        harness.validateCommitmentConfig(c);
    }

    function test_revert_minStakeTooHigh() public {
        CommitmentConfig memory c = _validConfig();
        c.minStake = 300_000_001;

        vm.expectPartialRevert(Errors.ConfigValueTooHigh.selector);
        harness.validateCommitmentConfig(c);
    }

    function test_validateFeeTiers_acceptsBaseFeeUpperBound() public view {
        FeeTier[] memory tiers = _validFeeTiers(1);
        tiers[0].baseFee = 250_000_000;

        harness.validateFeeTiers(tiers);
    }

    function test_validateFeeTiers_acceptsBaseOnlyPriceIncrease() public view {
        FeeTier[] memory tiers = _validFeeTiers(2);
        tiers[1].feeBps = tiers[0].feeBps;

        harness.validateFeeTiers(tiers);
    }

    function test_validateFeeTiers_acceptsPercentageOnlyPriceIncrease() public view {
        FeeTier[] memory tiers = _validFeeTiers(2);
        tiers[1].baseFee = tiers[0].baseFee;

        harness.validateFeeTiers(tiers);
    }

    function test_revert_tierBaseFeeTooHigh() public {
        FeeTier[] memory tiers = _validFeeTiers(1);
        tiers[0].baseFee = 250_000_001;

        vm.expectPartialRevert(Errors.ConfigValueTooHigh.selector);
        harness.validateFeeTiers(tiers);
    }

    function test_revert_tierCountOutOfRange() public {
        CommitmentConfig memory c = _validConfig();
        c.tierCount = 0;

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateCommitmentConfig(c);

        c.tierCount = 11;

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateCommitmentConfig(c);
    }

    function test_revert_maxBatchSizeOutOfRange() public {
        CommitmentConfig memory c = _validConfig();
        c.maxBatchSize = 0;

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateCommitmentConfig(c);

        c.maxBatchSize = 51;

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateCommitmentConfig(c);
    }

    function test_revert_feeTierBounds() public {
        FeeTier[] memory tiers = _validFeeTiers(3);
        tiers[0].feeBps = 99;

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateFeeTiers(tiers);

        tiers[0].feeBps = 501;

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateFeeTiers(tiers);
    }

    function test_revert_deadlineBounds() public {
        FeeTier[] memory tiers = _validFeeTiers(3);
        tiers[0].deadlineDays = 0;

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateFeeTiers(tiers);

        tiers[0].deadlineDays = 31;

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateFeeTiers(tiers);
    }

    function test_revert_feeTierOrdering() public {
        FeeTier[] memory tiers = _validFeeTiers(3);
        tiers[0].feeBps = 200;
        tiers[1].feeBps = 199;

        vm.expectRevert(Errors.InvalidTierOrdering.selector);
        harness.validateFeeTiers(tiers);
    }

    function test_revert_deadlineOrdering() public {
        FeeTier[] memory tiers = _validFeeTiers(3);
        tiers[1].deadlineDays = tiers[0].deadlineDays;

        vm.expectRevert(Errors.InvalidTierOrdering.selector);
        harness.validateFeeTiers(tiers);
    }

    function test_revert_baseFeeOrdering() public {
        FeeTier[] memory tiers = _validFeeTiers(3);
        tiers[1].baseFee = tiers[0].baseFee - 1;

        vm.expectRevert(Errors.InvalidTierOrdering.selector);
        harness.validateFeeTiers(tiers);
    }

    function test_revert_unchangedPriceForLongerDeadline() public {
        FeeTier[] memory tiers = _validFeeTiers(3);
        tiers[1].baseFee = tiers[0].baseFee;
        tiers[1].feeBps = tiers[0].feeBps;

        vm.expectRevert(Errors.InvalidTierOrdering.selector);
        harness.validateFeeTiers(tiers);
    }

    function test_revert_durationBoundsAndOrdering() public {
        CommitmentConfig memory c = _validConfig();
        c.maxStoppedDuration = uint32(29 days);

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateCommitmentConfig(c);

        c = _validConfig();
        c.maxActiveDuration = uint32(731 days);

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateCommitmentConfig(c);

        c = _validConfig();
        c.maxActiveDuration = c.maxStoppedDuration;

        vm.expectRevert(Errors.InvalidDurationOrdering.selector);
        harness.validateCommitmentConfig(c);
    }

    function test_revert_maxStoppedDurationTooHigh() public {
        CommitmentConfig memory c = _validConfig();
        c.maxStoppedDuration = uint32(366 days);

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateCommitmentConfig(c);
    }

    function test_revert_maxActiveDurationTooLow() public {
        CommitmentConfig memory c = _validConfig();
        c.maxActiveDuration = uint32(89 days);

        vm.expectPartialRevert(Errors.ConfigValueOutOfRange.selector);
        harness.validateCommitmentConfig(c);
    }

    function test_validateCommitmentConfig_acceptsDurationBoundaries() public view {
        CommitmentConfig memory low = _validConfig();
        low.maxStoppedDuration = uint32(30 days);
        low.maxActiveDuration = uint32(90 days);
        harness.validateCommitmentConfig(low);

        CommitmentConfig memory high = _validConfig();
        high.maxStoppedDuration = uint32(365 days);
        high.maxActiveDuration = uint32(730 days);
        harness.validateCommitmentConfig(high);
    }

    function test_revert_slashingRateTooHigh() public {
        CommitmentConfig memory c = _validConfig();
        c.harshSlashing.rate80 = 10001;

        vm.expectPartialRevert(Errors.ConfigValueTooHigh.selector);
        harness.validateCommitmentConfig(c);
    }

    function test_revert_slashingTableNotMonotonic() public {
        CommitmentConfig memory c = _validConfig();
        c.harshSlashing.rate80 = c.harshSlashing.rate70 + 1;

        vm.expectRevert(Errors.InvalidSlashingOrdering.selector);
        harness.validateCommitmentConfig(c);
    }

    function test_revert_harshLessThanSoft() public {
        CommitmentConfig memory c = _validConfig();
        c.harshSlashing.rate80 = c.softSlashing.rate80 - 1;

        vm.expectRevert(Errors.InvalidSlashingOrdering.selector);
        harness.validateCommitmentConfig(c);
    }
}
