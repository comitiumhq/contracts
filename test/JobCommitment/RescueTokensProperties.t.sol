// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";

contract RescueTokensPropertiesTest is JobCommitmentTestBase {
    function testFuzz_jcRescue_protectsApplicantStakes(uint256 surplusAmount) public {
        surplusAmount = bound(surplusAmount, 1, 1_000_000_000);

        // Create an application so there is real applicant stake
        _publishJob(0);
        _applyToJob(applicant1);

        // Send surplus tokens directly (simulating accidental transfer)
        usdc.mint(address(jobCommitment), surplusAmount);

        uint256 totalStakes = jobCommitment.totalApplicantStakes();
        uint256 jcBalance = usdc.balanceOf(address(jobCommitment));
        uint256 surplus = jcBalance - totalStakes;

        // Trying to rescue more than surplus should revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueExceedsSurplus.selector, surplus + 1, surplus));
        jobCommitment.rescueTokens(address(usdc), owner, surplus + 1);

        // Rescuing exact surplus should succeed
        vm.prank(owner);
        jobCommitment.rescueTokens(address(usdc), owner, surplus);

        // After rescue: balance still covers applicant stakes
        assertGe(
            usdc.balanceOf(address(jobCommitment)),
            jobCommitment.totalApplicantStakes(),
            "Balance must still cover applicant stakes after rescue"
        );
    }

    function testFuzz_jobFundsRescue_protectsAccounted(uint256 surplusAmount) public {
        surplusAmount = bound(surplusAmount, 1, 1_000_000_000);

        // Send surplus tokens directly
        usdc.mint(address(jobFunds), surplusAmount);

        uint256 totalAccounted = jobFunds.totalAccountedBalance();
        uint256 jobFundsBalance = usdc.balanceOf(address(jobFunds));
        uint256 surplus = jobFundsBalance - totalAccounted;

        // Trying to rescue more than surplus should revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueExceedsSurplus.selector, surplus + 1, surplus));
        jobFunds.rescueTokens(address(usdc), owner, surplus + 1);

        // Rescuing exact surplus should succeed
        vm.prank(owner);
        jobFunds.rescueTokens(address(usdc), owner, surplus);

        // After rescue: balance still >= totalAccountedBalance
        assertGe(
            usdc.balanceOf(address(jobFunds)),
            jobFunds.totalAccountedBalance(),
            "Balance must still cover accounted funds after rescue"
        );
    }
}
