// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";

contract RescueTokensPropertiesTest is JobCommitmentTestBase {
    function testFuzz_jobFundsRescue_protectsAccounted(uint256 surplusAmount) public {
        surplusAmount = bound(surplusAmount, 1, 1_000_000_000);

        usdc.mint(address(jobFunds), surplusAmount);

        uint256 totalAccounted = jobFunds.totalAccountedBalance();
        uint256 jobFundsBalance = usdc.balanceOf(address(jobFunds));
        uint256 surplus = jobFundsBalance - totalAccounted;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueExceedsSurplus.selector, surplus + 1, surplus));
        jobFunds.rescueTokens(address(usdc), owner, surplus + 1);

        vm.prank(owner);
        jobFunds.rescueTokens(address(usdc), owner, surplus);

        assertGe(
            usdc.balanceOf(address(jobFunds)),
            jobFunds.totalAccountedBalance(),
            "Balance must still cover accounted funds after rescue"
        );
    }
}
