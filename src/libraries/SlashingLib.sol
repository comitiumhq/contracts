// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BASIS_POINTS} from "../Constants.sol";
import {Errors} from "../Errors.sol";
import {SlashingTable} from "../types/ConfigTypes.sol";

/// @title SlashingLib
/// @notice Library for calculating slashing rates based on on-time response rate
/// @dev Callers select the harsh or soft table; the bracket algorithm is shared.
library SlashingLib {
    /// @notice Calculate slash rate for a configured table based on on-time response rate.
    /// @param table Slashing table with configurable rates per bracket
    /// @param totalApplications Total number of applications
    /// @param onTimeResponses Number of applications responded to before deadline
    /// @return slashBps Slash rate in basis points
    function calculateSlashRate(SlashingTable storage table, uint256 totalApplications, uint256 onTimeResponses)
        internal
        view
        returns (uint256 slashBps)
    {
        if (onTimeResponses > totalApplications) {
            revert Errors.InvalidSlashCounters(totalApplications, onTimeResponses);
        }

        if (totalApplications == 0) return 0;
        if (onTimeResponses == 0) return table.zeroResponseRate;

        uint256 responseRate = (onTimeResponses * 100) / totalApplications;

        if (responseRate == 100) return 0;
        if (responseRate >= 95) return table.rate95;
        if (responseRate >= 90) return table.rate90;
        if (responseRate >= 80) return table.rate80;
        if (responseRate >= 70) return table.rate70;
        if (responseRate >= 60) return table.rate60;
        if (responseRate >= 50) return table.rate50;

        return table.below50Rate; // 1-49%
    }

    /// @notice Calculate slashed and returned amounts
    /// @param stake Total stake amount
    /// @param slashBps Slash rate in basis points
    /// @return slashAmount Amount to be slashed and sent to the burn address
    /// @return returnAmount Amount to be returned to employer
    function calculateSlashAmounts(uint256 stake, uint256 slashBps)
        internal
        pure
        returns (uint256 slashAmount, uint256 returnAmount)
    {
        if (slashBps > BASIS_POINTS) revert Errors.InvalidSlashRate(slashBps);

        slashAmount = Math.mulDiv(stake, slashBps, BASIS_POINTS, Math.Rounding.Floor);
        returnAmount = stake - slashAmount;
    }
}
