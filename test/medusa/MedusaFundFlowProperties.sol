// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {EchidnaFundFlow} from "./FundFlowHarness.sol";

contract MedusaFundFlowProperties is EchidnaFundFlow {
    function property_commitmentFunds_accounting() public view returns (bool) {
        return _token.balanceOf(address(_mockCommitmentFunds)) >= _mockCommitmentFunds.lockedInCommitments();
    }
}
