// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";

contract RescueTokensPropertiesTest is ResponseCommitmentTestBase {
    function testFuzz_commitmentFundsRescue_protectsAccounted(uint256 surplusAmount) public {
        surplusAmount = bound(surplusAmount, 1, 1_000_000_000);

        usdc.mint(address(commitmentFunds), surplusAmount);

        uint256 totalAccounted = commitmentFunds.totalAccountedBalance();
        uint256 commitmentFundsBalance = usdc.balanceOf(address(commitmentFunds));
        uint256 surplus = commitmentFundsBalance - totalAccounted;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueExceedsSurplus.selector, surplus + 1, surplus));
        commitmentFunds.rescueTokens(address(usdc), owner, surplus + 1);

        vm.prank(owner);
        commitmentFunds.rescueTokens(address(usdc), owner, surplus);

        assertGe(
            usdc.balanceOf(address(commitmentFunds)),
            commitmentFunds.totalAccountedBalance(),
            "Balance must still cover accounted funds after rescue"
        );
    }
}
