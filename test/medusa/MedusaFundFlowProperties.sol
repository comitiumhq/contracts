// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {EchidnaFundFlow} from "./FundFlowHarness.sol";

contract MedusaFundFlowProperties is EchidnaFundFlow {
    function property_jobFunds_accounting() public view returns (bool) {
        return _token.balanceOf(address(_mockJobFunds)) >= _mockJobFunds.stakedInJobs();
    }
}
