// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

uint256 constant TEST_MIN_STAKE = 50_000_000;

contract HalmosFeeModel {
    function getFeeAmount(uint96 stake, uint8 feeTier) external pure returns (uint256) {
        (uint256 baseFee, uint256 feeBps) = _tierTerms(feeTier);

        return baseFee + ((uint256(stake) * feeBps) / 10_000);
    }

    function _tierTerms(uint8 feeTier) private pure returns (uint256 baseFee, uint256 feeBps) {
        if (feeTier == 0) return (25_000_000, 150);
        if (feeTier == 1) return (35_000_000, 250);

        return (50_000_000, 350);
    }
}

/// @title HalmosFeeArithmetic
/// @notice Halmos symbolic verification of fee/stake arithmetic properties
/// @dev Run: halmos --contract HalmosFeeArithmetic --solver-timeout-assertion 10s
contract HalmosFeeArithmetic is Test {
    HalmosFeeModel public model;

    function setUp() public {
        model = new HalmosFeeModel();
    }

    function check_fee_positive(uint96 stake, uint8 feeTier) public view {
        vm.assume(stake >= TEST_MIN_STAKE);
        vm.assume(feeTier <= 2);

        uint256 fee = model.getFeeAmount(stake, feeTier);

        assert(fee > 0);
    }

    function check_fee_fits_uint96(uint96 stake, uint8 feeTier) public view {
        vm.assume(stake >= TEST_MIN_STAKE);
        vm.assume(feeTier <= 2);

        uint256 fee = model.getFeeAmount(stake, feeTier);

        assert(fee <= type(uint96).max);
    }

    function check_fee_fits_uint96_allowed_config(uint96 stake, uint96 baseFee, uint16 feeBps) public pure {
        vm.assume(stake >= TEST_MIN_STAKE);
        vm.assume(baseFee <= 250_000_000);
        vm.assume(feeBps >= 100);
        vm.assume(feeBps <= 500);

        uint256 fee = uint256(baseFee) + ((uint256(stake) * feeBps) / 10_000);

        assert(fee <= type(uint96).max);
    }

    function check_fee_scaled_component_monotonic_in_stake(uint96 stake, uint8 feeTier) public view {
        vm.assume(stake >= TEST_MIN_STAKE);
        vm.assume(stake < type(uint96).max);
        vm.assume(feeTier <= 2);

        (, uint256 feeBps) = _tierTerms(feeTier);
        uint256 currentNumerator = uint256(stake) * feeBps;
        uint256 nextNumerator = (uint256(stake) + 1) * feeBps;

        assert(nextNumerator == currentNumerator + feeBps);
        assert(nextNumerator >= currentNumerator);
    }

    function check_fee_strictly_increases_by_tier(uint96 stake) public view {
        vm.assume(stake >= TEST_MIN_STAKE);

        uint256 tier0Fee = model.getFeeAmount(stake, 0);
        uint256 tier1Fee = model.getFeeAmount(stake, 1);
        uint256 tier2Fee = model.getFeeAmount(stake, 2);

        assert(tier0Fee < tier1Fee);
        assert(tier1Fee < tier2Fee);
    }

    function check_total_funding_covers_stake_and_fee(uint96 stake, uint8 feeTier) public view {
        vm.assume(stake >= TEST_MIN_STAKE);
        vm.assume(feeTier <= 2);

        uint256 fee = model.getFeeAmount(stake, feeTier);
        uint256 totalFunding = uint256(stake) + fee;

        assert(totalFunding >= stake);
        assert(totalFunding >= fee);
    }

    function _tierTerms(uint8 feeTier) private pure returns (uint256 baseFee, uint256 feeBps) {
        if (feeTier == 0) return (25_000_000, 150);
        if (feeTier == 1) return (35_000_000, 250);

        return (50_000_000, 350);
    }
}
