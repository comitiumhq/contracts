// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {SlashingLib} from "../../src/libraries/SlashingLib.sol";
import {SlashingTable} from "../../src/types/ConfigTypes.sol";

contract SlashingMonotonicityHarness {
    SlashingTable public harshTable;
    SlashingTable public softTable;

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

    function harshSlashRate(uint256 total, uint256 onTime) external view returns (uint256) {
        return SlashingLib.calculateSlashRate(harshTable, total, onTime);
    }

    function softSlashRate(uint256 total, uint256 onTime) external view returns (uint256) {
        return SlashingLib.calculateSlashRate(softTable, total, onTime);
    }
}

contract SlashingMonotonicityTest is Test {
    SlashingMonotonicityHarness harness;

    function setUp() public {
        harness = new SlashingMonotonicityHarness();
    }

    function testFuzz_harsh_monotonicity(uint256 totalApps, uint256 onTime1, uint256 onTime2) public view {
        totalApps = bound(totalApps, 1, 10000);
        onTime1 = bound(onTime1, 0, totalApps);
        onTime2 = bound(onTime2, onTime1, totalApps);

        uint256 rate1 = harness.harshSlashRate(totalApps, onTime1);
        uint256 rate2 = harness.harshSlashRate(totalApps, onTime2);

        assertLe(rate2, rate1, "More on-time should not increase harsh slash rate");
    }

    function testFuzz_soft_monotonicity(uint256 totalApps, uint256 onTime1, uint256 onTime2) public view {
        totalApps = bound(totalApps, 1, 10000);
        onTime1 = bound(onTime1, 0, totalApps);
        onTime2 = bound(onTime2, onTime1, totalApps);

        uint256 rate1 = harness.softSlashRate(totalApps, onTime1);
        uint256 rate2 = harness.softSlashRate(totalApps, onTime2);

        assertLe(rate2, rate1, "More on-time should not increase soft slash rate");
    }

    function testFuzz_harsh_bracket_boundaries(uint256 totalApps) public view {
        totalApps = bound(totalApps, 100, 10000);

        // 100% on-time response always gives 0 slash.
        uint256 rate100 = harness.harshSlashRate(totalApps, totalApps);
        assertEq(rate100, 0, "100% on-time response must give 0 slash");

        // 0% on-time response always gives zeroResponseRate (10000).
        uint256 rate0 = harness.harshSlashRate(totalApps, 0);
        assertEq(rate0, 10000, "0% on-time response must give max slash");

        // Rate at 50% mark should be >= rate at 95% mark (monotonicity at boundaries)
        uint256 onTime50 = (totalApps * 50) / 100;
        uint256 onTime95 = (totalApps * 95) / 100;
        uint256 rateAt50 = harness.harshSlashRate(totalApps, onTime50);
        uint256 rateAt95 = harness.harshSlashRate(totalApps, onTime95);
        assertGe(rateAt50, rateAt95, "50% mark must have >= slash than 95% mark");
    }

    function testFuzz_harsh_scaling(uint256 total, uint256 onTime, uint256 scale) public view {
        total = bound(total, 1, 1000);
        onTime = bound(onTime, 0, total);
        scale = bound(scale, 1, 10);

        uint256 rate1 = harness.harshSlashRate(total, onTime);
        uint256 rate2 = harness.harshSlashRate(total * scale, onTime * scale);

        assertEq(rate1, rate2, "Same ratio at different scales should give same rate");
    }
}
