// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {OrgCommitmentBalance} from "../../src/interfaces/ICommitmentFunds.sol";

import {OrgTestBase} from "../shared/OrgTestBase.sol";

contract OrgBalanceScenariosTest is OrgTestBase {
    uint256 orgId;
    uint256 nextCommitmentId = 1;

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "inv.com");
        vm.startPrank(contractOwner);
        commitmentFunds.registerResponseCommitment(address(this), 1);
        commitmentFunds.setCurrentResponseCommitment(address(this));
        vm.stopPrank();
    }

    function testFuzz_totalAccountedBalance_tracksDepositsWithdraws(
        uint256 deposit1,
        uint256 deposit2,
        uint256 withdraw1
    ) public {
        deposit1 = bound(deposit1, 1, type(uint96).max / 4);
        deposit2 = bound(deposit2, 1, type(uint96).max / 4);

        _fundAndDeposit(orgId, orgOwner1, deposit1);
        _fundAndDeposit(orgId, orgOwner1, deposit2);

        uint256 total = deposit1 + deposit2;
        assertEq(commitmentFunds.totalAccountedBalance(), total);

        withdraw1 = bound(withdraw1, 0, total);
        if (withdraw1 > 0) {
            vm.prank(orgOwner1);
            commitmentFunds.withdraw(orgId, withdraw1);
        }

        assertEq(commitmentFunds.totalAccountedBalance(), total - withdraw1);

        assertGe(usdc.balanceOf(address(commitmentFunds)), commitmentFunds.totalAccountedBalance());
    }

    function testFuzz_totalAccountedBalance_tracksFundAndSettle(
        uint256 deposit,
        uint256 stake,
        uint256 fee,
        uint256 returnAmount
    ) public {
        deposit = bound(deposit, 100, type(uint96).max / 4);
        stake = bound(stake, 1, deposit / 2);
        fee = bound(fee, 0, stake / 20);
        returnAmount = bound(returnAmount, 0, stake);

        // Need enough balance for stake + fee
        _fundAndDeposit(orgId, orgOwner1, deposit);

        uint256 accountedBefore = commitmentFunds.totalAccountedBalance();
        assertEq(accountedBefore, deposit);

        assertEq(_activateTestCommitment(address(this), orgId, orgOwner1, stake, fee), nextCommitmentId);

        assertEq(commitmentFunds.totalAccountedBalance(), deposit - fee);

        commitmentFunds.settleCommitment(orgId, nextCommitmentId, returnAmount);

        uint256 slashed = stake - returnAmount;
        assertEq(commitmentFunds.totalAccountedBalance(), deposit - fee - slashed);

        assertGe(usdc.balanceOf(address(commitmentFunds)), commitmentFunds.totalAccountedBalance());
    }

    function testFuzz_lockedNeverExceedsOperational(uint256 deposit, uint256 stake1, uint256 stake2, uint256 return1)
        public
    {
        deposit = bound(deposit, 100, type(uint96).max / 4);
        stake1 = bound(stake1, 1, deposit / 3);
        stake2 = bound(stake2, 1, deposit / 3);
        return1 = bound(return1, 0, stake1);

        _fundAndDeposit(orgId, orgOwner1, deposit);

        _activateTestCommitment(address(this), orgId, orgOwner1, stake1, 0);
        _assertLockedLeqOperational();

        _activateTestCommitment(address(this), orgId, orgOwner1, stake2, 0);
        _assertLockedLeqOperational();

        commitmentFunds.settleCommitment(orgId, 1, return1);
        _assertLockedLeqOperational();

        commitmentFunds.settleCommitment(orgId, 2, stake2);
        _assertLockedLeqOperational();
    }

    function testFuzz_multiOrg_independent(uint256 dep1, uint256 dep2) public {
        dep1 = bound(dep1, 1, type(uint96).max / 4);
        dep2 = bound(dep2, 1, type(uint96).max / 4);

        uint256 org2 = _createOrg(orgOwner2, "org2.com");

        _fundAndDeposit(orgId, orgOwner1, dep1);
        _fundAndDeposit(org2, orgOwner2, dep2);

        assertEq(commitmentFunds.availableBalance(orgId), dep1);
        assertEq(commitmentFunds.availableBalance(org2), dep2);

        // Withdraw from org1 doesn't affect org2
        vm.prank(orgOwner1);
        commitmentFunds.withdraw(orgId, dep1);

        assertEq(commitmentFunds.availableBalance(orgId), 0);
        assertEq(commitmentFunds.availableBalance(org2), dep2);

        assertEq(commitmentFunds.totalAccountedBalance(), dep2);

        assertGe(usdc.balanceOf(address(commitmentFunds)), commitmentFunds.totalAccountedBalance());
    }

    function testFuzz_fullLifecycle(uint256 deposit, uint8 numCommitments) public {
        deposit = bound(deposit, 1000, type(uint96).max / 4);
        numCommitments = uint8(bound(numCommitments, 1, 5));

        _fundAndDeposit(orgId, orgOwner1, deposit);

        uint256 stakePerCommitment = deposit / (numCommitments * 2); // leave room
        uint256 totalLocked;

        // Fund commitments
        for (uint8 i = 0; i < numCommitments; i++) {
            assertEq(
                _activateTestCommitment(address(this), orgId, orgOwner1, stakePerCommitment, 0), nextCommitmentId + i
            );
            totalLocked += stakePerCommitment;
            _assertLockedLeqOperational();
        }

        // Settle all with half return
        uint256 totalSlashed;
        for (uint8 i = 0; i < numCommitments; i++) {
            uint256 returnAmt = stakePerCommitment / 2;
            commitmentFunds.settleCommitment(orgId, nextCommitmentId + i, returnAmt);
            totalSlashed += stakePerCommitment - returnAmt;
            _assertLockedLeqOperational();
        }

        OrgCommitmentBalance memory org = commitmentFunds.commitmentBalance(orgId);
        assertEq(org.lockedInCommitments, 0);
        assertEq(org.available, deposit - totalSlashed);

        uint256 remaining = commitmentFunds.availableBalance(orgId);
        if (remaining > 0) {
            vm.prank(orgOwner1);
            commitmentFunds.withdraw(orgId, remaining);
        }

        assertEq(commitmentFunds.availableBalance(orgId), 0);
        assertGe(usdc.balanceOf(address(commitmentFunds)), commitmentFunds.totalAccountedBalance());
    }

    function _assertLockedLeqOperational() internal view {
        OrgCommitmentBalance memory org = commitmentFunds.commitmentBalance(orgId);
        assertLe(org.lockedInCommitments, commitmentFunds.totalAccountedBalance(), "locked must be accounted");
    }
}
