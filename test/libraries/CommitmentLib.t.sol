// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {CommitmentLib} from "../../src/libraries/CommitmentLib.sol";
import {FeeTier} from "../../src/types/ConfigTypes.sol";
import {BASIS_POINTS} from "../../src/Constants.sol";

// Default values matching constructor config
uint96 constant TEST_MIN_STAKE = 50_000_000;
uint96 constant TEST_BASE_FEE_TIER_0 = 25_000_000;
uint96 constant TEST_BASE_FEE_TIER_1 = 35_000_000;
uint96 constant TEST_BASE_FEE_TIER_2 = 50_000_000;
uint256 constant TEST_FEE_TIER_0 = 150;
uint256 constant TEST_FEE_TIER_1 = 250;
uint256 constant TEST_FEE_TIER_2 = 350;
uint8 constant TEST_DEADLINE_DAYS_TIER_1 = 7;

/// @notice Harness contract that holds fee tiers in storage so library internal functions can be called.
contract CommitmentLibHarness {
    mapping(uint8 tier => FeeTier) public feeTiers;

    constructor() {
        feeTiers[0] = FeeTier({baseFee: TEST_BASE_FEE_TIER_0, feeBps: 150, deadlineDays: 3});
        feeTiers[1] = FeeTier({baseFee: TEST_BASE_FEE_TIER_1, feeBps: 250, deadlineDays: 7});
        feeTiers[2] = FeeTier({baseFee: TEST_BASE_FEE_TIER_2, feeBps: 350, deadlineDays: 14});
    }

    function getFeeAmount(uint96 stake, uint8 feeTier) external view returns (uint256) {
        return CommitmentLib.getFeeAmount(feeTiers[feeTier], stake);
    }

    function setFeeTier(uint8 feeTier, FeeTier calldata tier) external {
        feeTiers[feeTier] = tier;
    }

    function getResponseDeadline(uint256 applicationTime, uint8 deadlineDays) external pure returns (uint256) {
        return CommitmentLib.getResponseDeadline(applicationTime, deadlineDays);
    }
}

contract CommitmentLibTest is Test {
    CommitmentLibHarness public harness;

    function setUp() public {
        harness = new CommitmentLibHarness();
    }

    // ============ getFeeAmount Tests ============

    function test_getFeeAmount_minStake_tier0() public view {
        // 50 USDC * 1.5% + 25 USDC base fee = 25.75 USDC
        uint256 fee = harness.getFeeAmount(TEST_MIN_STAKE, 0);
        assertEq(fee, 25_750_000);
    }

    function test_getFeeAmount_minStake_tier1() public view {
        // 50 USDC * 2.5% + 35 USDC base fee = 36.25 USDC
        uint256 fee = harness.getFeeAmount(TEST_MIN_STAKE, 1);
        assertEq(fee, 36_250_000);
    }

    function test_getFeeAmount_minStake_tier2() public view {
        // 50 USDC * 3.5% + 50 USDC base fee = 51.75 USDC
        uint256 fee = harness.getFeeAmount(TEST_MIN_STAKE, 2);
        assertEq(fee, 51_750_000);
    }

    function test_getFeeAmount_1000USDC_tier0() public view {
        // 1000 USDC * 1.5% + 25 USDC base fee = 40 USDC
        uint96 stake = 1000_000_000; // 1000 USDC
        uint256 fee = harness.getFeeAmount(stake, 0);
        assertEq(fee, 40_000_000);
    }

    function test_getFeeAmount_100USDC_allTiers() public view {
        uint96 stake = 100_000_000;

        assertEq(harness.getFeeAmount(stake, 0), 26_500_000);
        assertEq(harness.getFeeAmount(stake, 1), 37_500_000);
        assertEq(harness.getFeeAmount(stake, 2), 53_500_000);
    }

    function test_getFeeAmount_uint96SignBoundary_tier2() public view {
        uint96 stake = uint96(1) << 95;
        uint256 expected = 50_000_000 + ((uint256(stake) * 350) / BASIS_POINTS);

        assertEq(harness.getFeeAmount(stake, 2), expected);
    }

    function test_getFeeAmount_maxUint96_tier2() public view {
        uint96 stake = type(uint96).max;
        uint256 expected = 50_000_000 + ((uint256(stake) * 350) / BASIS_POINTS);

        assertEq(harness.getFeeAmount(stake, 2), expected);
        assertLe(expected, type(uint96).max);
    }

    function test_getFeeAmount_maxAllowedDomain_fitsUint96() public {
        FeeTier memory maximumTier = FeeTier({baseFee: 250_000_000, feeBps: 500, deadlineDays: 30});
        harness.setFeeTier(2, maximumTier);

        uint96 stake = type(uint96).max;
        uint256 expected = uint256(maximumTier.baseFee) + ((uint256(stake) * maximumTier.feeBps) / BASIS_POINTS);

        assertEq(harness.getFeeAmount(stake, 2), expected);
        assertLe(expected, type(uint96).max);
    }

    function testFuzz_getFeeAmount(uint96 stake, uint8 feeTier) public view {
        vm.assume(feeTier <= 2);

        uint256 fee = harness.getFeeAmount(stake, feeTier);
        uint96[3] memory baseFees = [TEST_BASE_FEE_TIER_0, TEST_BASE_FEE_TIER_1, TEST_BASE_FEE_TIER_2];
        uint256[3] memory feeBps = [TEST_FEE_TIER_0, TEST_FEE_TIER_1, TEST_FEE_TIER_2];
        uint256 expectedFee = baseFees[feeTier] + ((stake * feeBps[feeTier]) / BASIS_POINTS);
        assertEq(fee, expectedFee);
    }

    function testFuzz_getFeeAmount_monotonicInStake(uint96 stake, uint8 feeTier) public view {
        vm.assume(stake < type(uint96).max);
        vm.assume(feeTier <= 2);

        assertLe(harness.getFeeAmount(stake, feeTier), harness.getFeeAmount(stake + 1, feeTier));
    }

    function testFuzz_getFeeAmount_strictlyIncreasesByTier(uint96 stake) public view {
        uint256 tier0Fee = harness.getFeeAmount(stake, 0);
        uint256 tier1Fee = harness.getFeeAmount(stake, 1);
        uint256 tier2Fee = harness.getFeeAmount(stake, 2);

        assertLt(tier0Fee, tier1Fee);
        assertLt(tier1Fee, tier2Fee);
    }

    // ============ getResponseDeadline Tests ============

    function test_getResponseDeadline() public view {
        uint256 applicationTime = 1_700_000_000;

        assertEq(
            harness.getResponseDeadline(applicationTime, TEST_DEADLINE_DAYS_TIER_1),
            applicationTime + uint256(TEST_DEADLINE_DAYS_TIER_1) * 1 days
        );
    }
}
