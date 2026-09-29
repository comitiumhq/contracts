// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {EchidnaCommitmentLifecycle} from "./LifecycleHarness.sol";
import {Commitment} from "../../src/types/CommitmentTypes.sol";

contract MedusaLifecycleProperties is EchidnaCommitmentLifecycle {
    function property_status_monotonic() public view returns (bool) {
        for (uint256 i = 0; i < allCommitmentIds.length; i++) {
            uint256 commitmentId = allCommitmentIds[i];
            Commitment storage commitment = _commitment(commitmentId);
            if (uint8(commitment.status) < prevStatus[commitmentId]) return false;
        }
        return true;
    }
}
