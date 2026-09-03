// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {SlashingLib} from "../../src/libraries/SlashingLib.sol";
import {SlashingTable} from "../../src/types/ConfigTypes.sol";
import {BASIS_POINTS} from "../../src/Constants.sol";

/// @notice Harness that holds SlashingTable in storage for Halmos symbolic verification
contract HalmosSlashingHarness {
    SlashingTable public harshTable;
    SlashingTable public softTable;
    SlashingTable public customTable;

    constructor() {
        harshTable = SlashingTable({
            zeroResponseRate: 10000,
            below50Rate: 5000,
            rate50: 3500,
            rate60: 2500,
            rate70: 1800,
            rate80: 1000,
            rate90: 500,
            rate95: 200
        });
        softTable = SlashingTable({
            zeroResponseRate: 3000,
            below50Rate: 2500,
            rate50: 2200,
            rate60: 1800,
            rate70: 1200,
            rate80: 800,
            rate90: 500,
            rate95: 200
        });
    }

    function setCustomTable(SlashingTable calldata table) external {
        customTable = table;
    }

    function calculateSlashRate(uint256 total, uint256 onTime) external view returns (uint256) {
        return SlashingLib.calculateSlashRate(harshTable, total, onTime);
    }

    function calculateSoftSlashRate(uint256 total, uint256 onTime) external view returns (uint256) {
        return SlashingLib.calculateSlashRate(softTable, total, onTime);
    }

    function calculateCustomSlashRate(uint256 total, uint256 onTime) external view returns (uint256) {
        return SlashingLib.calculateSlashRate(customTable, total, onTime);
    }

    function calculateSlashAmounts(uint256 stake, uint256 slashBps) external pure returns (uint256, uint256) {
        return SlashingLib.calculateSlashAmounts(stake, slashBps);
    }
}

/// @title HalmosSlashing
/// @notice Halmos symbolic verification of SlashingLib properties
/// @dev Run: halmos --contract HalmosSlashing --solver-timeout-assertion 600
contract HalmosSlashing is Test {
    HalmosSlashingHarness public harness;

    function setUp() public {
        harness = new HalmosSlashingHarness();
    }

    // ============ Property 1: Slash amount conservation ============

    function check_conservation_overSlashRate(uint96 stake, uint16 slashRate) public view {
        vm.assume(slashRate <= BASIS_POINTS);
        (uint256 slashAmount, uint256 returnAmount) = harness.calculateSlashAmounts(stake, slashRate);

        assert(slashAmount + returnAmount == stake);
    }

    // ============ Property 2: Rate bounded for any valid slashing table ============

    function check_rate_bounded_anyTable(
        uint16 totalApps,
        uint16 onTime,
        uint16 zero,
        uint16 below50,
        uint16 rate50,
        uint16 rate60,
        uint16 rate70,
        uint16 rate80,
        uint16 rate90,
        uint16 rate95
    ) public {
        vm.assume(onTime <= totalApps);
        vm.assume(zero <= BASIS_POINTS);
        vm.assume(rate95 <= rate90);
        vm.assume(rate90 <= rate80);
        vm.assume(rate80 <= rate70);
        vm.assume(rate70 <= rate60);
        vm.assume(rate60 <= rate50);
        vm.assume(rate50 <= below50);
        vm.assume(below50 <= zero);

        harness.setCustomTable(
            SlashingTable({
                zeroResponseRate: zero,
                below50Rate: below50,
                rate50: rate50,
                rate60: rate60,
                rate70: rate70,
                rate80: rate80,
                rate90: rate90,
                rate95: rate95
            })
        );

        uint256 rate = harness.calculateCustomSlashRate(totalApps, onTime);
        assert(rate <= BASIS_POINTS);
    }

    // ============ Property 3: More on-time responses never increase slash rate ============

    function check_harsh_monotonic_in_onTime(uint16 totalApps, uint16 lowerOnTime, uint16 higherOnTime) public view {
        vm.assume(totalApps > 0);
        vm.assume(lowerOnTime <= higherOnTime);
        vm.assume(higherOnTime <= totalApps);

        uint256 lowerRate = harness.calculateSlashRate(totalApps, lowerOnTime);
        uint256 higherRate = harness.calculateSlashRate(totalApps, higherOnTime);

        assert(higherRate <= lowerRate);
    }

    function check_soft_monotonic_in_onTime(uint16 totalApps, uint16 lowerOnTime, uint16 higherOnTime) public view {
        vm.assume(totalApps > 0);
        vm.assume(lowerOnTime <= higherOnTime);
        vm.assume(higherOnTime <= totalApps);

        uint256 lowerRate = harness.calculateSoftSlashRate(totalApps, lowerOnTime);
        uint256 higherRate = harness.calculateSoftSlashRate(totalApps, higherOnTime);

        assert(higherRate <= lowerRate);
    }
}
