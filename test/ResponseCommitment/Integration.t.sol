// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {CommitmentView} from "../../src/interfaces/IResponseCommitment.sol";
import {CommitmentStatus} from "../../src/types/CommitmentTypes.sol";

contract IntegrationTest is ResponseCommitmentTestBase {
    function test_fullFlow_respondAndSettle() public {
        uint256 applicantBalance = usdc.balanceOf(applicant1);
        uint256 commitmentId = _activateCommitment(0);
        bytes32 applicationId = _submitApplication(applicant1);

        _respondToApplication(applicationId);
        _stopCommitment(commitmentId);
        _settleCommitment(commitmentId, 1, 1, 1);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Settled));
        assertEq(usdc.balanceOf(applicant1), applicantBalance);
        assertEq(usdc.balanceOf(address(responseCommitment)), 0);
    }
}
