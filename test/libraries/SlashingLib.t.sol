// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Errors} from "../../src/Errors.sol";
import {SlashingLib} from "../../src/libraries/SlashingLib.sol";
import {SlashingTable} from "../../src/types/ConfigTypes.sol";
import {BASIS_POINTS} from "../../src/Constants.sol";

/// @notice Harness contract that holds SlashingTable in storage so library external functions can be called
contract SlashingLibHarness {
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

    function calculateSlashRate(uint256 total, uint256 onTime) external view returns (uint256) {
        return SlashingLib.calculateSlashRate(harshTable, total, onTime);
    }

    function calculateSoftSlashRate(uint256 total, uint256 onTime) external view returns (uint256) {
        return SlashingLib.calculateSlashRate(softTable, total, onTime);
    }

    function calculateSlashAmounts(uint256 stake, uint256 slashBps) external pure returns (uint256, uint256) {
        return SlashingLib.calculateSlashAmounts(stake, slashBps);
    }
}

contract SlashingLibTest is Test {
    SlashingLibHarness public harness;

    function setUp() public {
        harness = new SlashingLibHarness();
    }

    // ============ calculateSlashRate Tests ============
    // Harsh slashing rate used when expired settlement has unanswered applications.

    function test_slash_100percent_response() public view {
        // 100% on-time response = 0% slash
        assertEq(harness.calculateSlashRate(10, 10), 0);
        assertEq(harness.calculateSlashRate(100, 100), 0);
        assertEq(harness.calculateSlashRate(1, 1), 0);
    }

    function test_slash_95to99percent_response() public view {
        // 95-99% on-time response = 2% slash (200 bps)
        assertEq(harness.calculateSlashRate(100, 99), 200);
        assertEq(harness.calculateSlashRate(100, 95), 200);
        assertEq(harness.calculateSlashRate(20, 19), 200); // 95%
    }

    function test_slash_90to94percent_response() public view {
        // 90-94% on-time response = 5% slash (500 bps)
        assertEq(harness.calculateSlashRate(100, 94), 500);
        assertEq(harness.calculateSlashRate(100, 90), 500);
        assertEq(harness.calculateSlashRate(10, 9), 500); // 90%
    }

    function test_slash_80to89percent_response() public view {
        // 80-89% on-time response = 10% slash (1000 bps)
        assertEq(harness.calculateSlashRate(100, 89), 1000);
        assertEq(harness.calculateSlashRate(100, 80), 1000);
        assertEq(harness.calculateSlashRate(10, 8), 1000); // 80%
    }

    function test_slash_70to79percent_response() public view {
        // 70-79% on-time response = 18% slash (1800 bps)
        assertEq(harness.calculateSlashRate(100, 79), 1800);
        assertEq(harness.calculateSlashRate(100, 70), 1800);
        assertEq(harness.calculateSlashRate(10, 7), 1800); // 70%
    }

    function test_slash_60to69percent_response() public view {
        // 60-69% on-time response = 25% slash (2500 bps)
        assertEq(harness.calculateSlashRate(100, 69), 2500);
        assertEq(harness.calculateSlashRate(100, 60), 2500);
    }

    function test_slash_50to59percent_response() public view {
        // 50-59% on-time response = 35% slash (3500 bps)
        assertEq(harness.calculateSlashRate(100, 59), 3500);
        assertEq(harness.calculateSlashRate(100, 50), 3500);
        assertEq(harness.calculateSlashRate(10, 5), 3500); // 50%
    }

    function test_slash_1to49percent_response() public view {
        // 1-49% on-time response = 50% slash (5000 bps)
        assertEq(harness.calculateSlashRate(100, 49), 5000);
        assertEq(harness.calculateSlashRate(100, 1), 5000);
    }

    function test_slash_0percent_response() public view {
        // 0% on-time response = 100% slash
        assertEq(harness.calculateSlashRate(100, 0), BASIS_POINTS);
        assertEq(harness.calculateSlashRate(10, 0), BASIS_POINTS);
        assertEq(harness.calculateSlashRate(1, 0), BASIS_POINTS);
    }

    function test_slash_noApplications() public view {
        // No applications = no slash (nothing to respond to)
        assertEq(harness.calculateSlashRate(0, 0), 0);
    }

    function test_slash_revert_onTimeExceedsTotal() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSlashCounters.selector, 10, 11));
        harness.calculateSlashRate(10, 11);
    }

    // ============ calculateSlashAmounts Tests ============

    function test_calculateSlashAmounts_0percentSlash() public view {
        uint256 stake = 300_000_000; // 300 USDC
        (uint256 slashed, uint256 returned) = harness.calculateSlashAmounts(stake, 0);

        assertEq(slashed, 0);
        assertEq(returned, stake);
    }

    function test_calculateSlashAmounts_5percentSlash() public view {
        uint256 stake = 300_000_000; // 300 USDC
        (uint256 slashed, uint256 returned) = harness.calculateSlashAmounts(stake, 500);

        assertEq(slashed, 15_000_000); // 15 USDC
        assertEq(returned, 285_000_000); // 285 USDC
    }

    function test_calculateSlashAmounts_50percentSlash() public view {
        uint256 stake = 300_000_000; // 300 USDC
        (uint256 slashed, uint256 returned) = harness.calculateSlashAmounts(stake, 5000);

        assertEq(slashed, 150_000_000); // 150 USDC
        assertEq(returned, 150_000_000); // 150 USDC
    }

    function test_calculateSlashAmounts_100percentSlash() public view {
        uint256 stake = 300_000_000; // 300 USDC
        (uint256 slashed, uint256 returned) = harness.calculateSlashAmounts(stake, BASIS_POINTS);

        assertEq(slashed, stake);
        assertEq(returned, 0);
    }

    function test_calculateSlashAmounts_revert_rateAboveBasisPoints() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidSlashRate.selector, BASIS_POINTS + 1));
        harness.calculateSlashAmounts(300_000_000, BASIS_POINTS + 1);
    }

    function testFuzz_calculateSlashAmounts(uint256 stake, uint256 slashBps) public view {
        vm.assume(stake <= type(uint96).max);
        vm.assume(slashBps <= BASIS_POINTS);

        (uint256 slashed, uint256 returned) = harness.calculateSlashAmounts(stake, slashBps);

        // Slashed + returned should equal original stake
        assertEq(slashed + returned, stake);

        // Slashed amount should be correct percentage
        uint256 expectedSlashed = (stake * slashBps) / BASIS_POINTS;
        assertEq(slashed, expectedSlashed);
    }

    // ============ calculateSoftSlashRate Tests ============
    // Soft slashing rate used for closeJob() when all applications responded but some late

    function test_lateSlash_100percent_onTime() public view {
        // 100% on-time = 0% slash
        assertEq(harness.calculateSoftSlashRate(10, 10), 0);
        assertEq(harness.calculateSoftSlashRate(100, 100), 0);
        assertEq(harness.calculateSoftSlashRate(1, 1), 0);
    }

    function test_lateSlash_95to99percent_onTime() public view {
        // 95-99% on-time = 2% slash (200 bps)
        assertEq(harness.calculateSoftSlashRate(100, 99), 200);
        assertEq(harness.calculateSoftSlashRate(100, 95), 200);
        assertEq(harness.calculateSoftSlashRate(20, 19), 200); // 95%
    }

    function test_lateSlash_90to94percent_onTime() public view {
        // 90-94% on-time = 5% slash (500 bps)
        assertEq(harness.calculateSoftSlashRate(100, 94), 500);
        assertEq(harness.calculateSoftSlashRate(100, 90), 500);
        assertEq(harness.calculateSoftSlashRate(10, 9), 500); // 90%
    }

    function test_lateSlash_80to89percent_onTime() public view {
        // 80-89% on-time = 8% slash (800 bps)
        assertEq(harness.calculateSoftSlashRate(100, 89), 800);
        assertEq(harness.calculateSoftSlashRate(100, 80), 800);
        assertEq(harness.calculateSoftSlashRate(10, 8), 800); // 80%
    }

    function test_lateSlash_70to79percent_onTime() public view {
        // 70-79% on-time = 12% slash (1200 bps)
        assertEq(harness.calculateSoftSlashRate(100, 79), 1200);
        assertEq(harness.calculateSoftSlashRate(100, 70), 1200);
        assertEq(harness.calculateSoftSlashRate(10, 7), 1200); // 70%
    }

    function test_lateSlash_60to69percent_onTime() public view {
        // 60-69% on-time = 18% slash (1800 bps)
        assertEq(harness.calculateSoftSlashRate(100, 69), 1800);
        assertEq(harness.calculateSoftSlashRate(100, 60), 1800);
    }

    function test_lateSlash_50to59percent_onTime() public view {
        // 50-59% on-time = 22% slash (2200 bps)
        assertEq(harness.calculateSoftSlashRate(100, 59), 2200);
        assertEq(harness.calculateSoftSlashRate(100, 50), 2200);
        assertEq(harness.calculateSoftSlashRate(10, 5), 2200); // 50%
    }

    function test_lateSlash_1to49percent_onTime() public view {
        // 1-49% on-time = 25% slash (2500 bps)
        assertEq(harness.calculateSoftSlashRate(100, 49), 2500);
        assertEq(harness.calculateSoftSlashRate(100, 1), 2500);
    }

    function test_lateSlash_0percent_onTime() public view {
        // 0% on-time = 30% slash (all late)
        assertEq(harness.calculateSoftSlashRate(100, 0), 3000);
        assertEq(harness.calculateSoftSlashRate(10, 0), 3000);
        assertEq(harness.calculateSoftSlashRate(1, 0), 3000);
    }

    function test_lateSlash_noApplications() public view {
        // No applications = no slash (nothing to respond to)
        assertEq(harness.calculateSoftSlashRate(0, 0), 0);
    }
}
