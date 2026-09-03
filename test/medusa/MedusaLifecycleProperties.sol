// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {EchidnaJobLifecycle} from "./LifecycleHarness.sol";
import {Job} from "../../src/types/JobTypes.sol";

contract MedusaLifecycleProperties is EchidnaJobLifecycle {
    function property_status_monotonic() public view returns (bool) {
        for (uint256 i = 0; i < allJobIds.length; i++) {
            uint256 jobId = allJobIds[i];
            Job storage job = _job(jobId);
            if (uint8(job.status) < prevStatus[jobId]) return false;
        }
        return true;
    }

    function property_orgStakeSettled_monotonic() public view returns (bool) {
        for (uint256 i = 0; i < allJobIds.length; i++) {
            uint256 jobId = allJobIds[i];
            Job storage job = _job(jobId);
            if (prevOrgStakeSettled[jobId] && !job.orgStakeSettled) return false;
        }
        return true;
    }
}
