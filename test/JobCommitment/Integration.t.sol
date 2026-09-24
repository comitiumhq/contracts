// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {JobView} from "../../src/interfaces/IJobCommitment.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";

contract IntegrationTest is JobCommitmentTestBase {
    function test_fullFlow_respondAndClose() public {
        uint256 applicantBalance = usdc.balanceOf(applicant1);
        uint256 jobId = _publishJob(0);
        bytes32 applicationId = _submitApplication(applicant1);

        _respondToApplication(applicationId);
        _unpublishJob(jobId);
        _closeJob(jobId, 1, 1, 1);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Closed));
        assertTrue(job.orgStakeSettled);
        assertEq(usdc.balanceOf(applicant1), applicantBalance);
        assertEq(usdc.balanceOf(address(jobCommitment)), 0);
    }
}
