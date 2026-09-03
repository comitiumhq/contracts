// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {BASIS_POINTS} from "../Constants.sol";
import {FeeTier} from "../types/ConfigTypes.sol";

/// @title JobLib
/// @notice Library for job-related calculations.
library JobLib {
    /// @notice Get the total non-refundable job fee.
    /// @param tier Validated fee tier.
    /// @param stake Employer stake amount.
    /// @return fee Base fee plus stake-scaled tier fee.
    function getFeeAmount(FeeTier storage tier, uint96 stake) internal view returns (uint256 fee) {
        uint256 stakeFee = (uint256(stake) * tier.feeBps) / BASIS_POINTS;

        return uint256(tier.baseFee) + stakeFee;
    }

    /// @notice Calculate the response deadline timestamp for an application.
    /// @param applicationTime Timestamp when application was submitted.
    /// @param deadlineDays Number of days for employer to respond.
    /// @return deadline Timestamp by which employer must respond.
    function getResponseDeadline(uint256 applicationTime, uint8 deadlineDays) internal pure returns (uint256 deadline) {
        return applicationTime + (uint256(deadlineDays) * 1 days);
    }
}
