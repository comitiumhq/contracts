// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {IJobFunds} from "../../src/interfaces/IJobFunds.sol";
import {Errors} from "../../src/Errors.sol";

import {OrgTestBase} from "../shared/OrgTestBase.sol";

contract JobFundsAuthorityTest is OrgTestBase {
    uint256 orgId;

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "test.com");
        _fundAndDeposit(orgId, orgOwner1, 1_000_000_000);
    }

    function test_creatorHasImplicitOrgAdminJobManagementAuthority() public view {
        assertTrue(registry.isOrgAdmin(orgId, orgOwner1));
        assertFalse(jobFunds.isJobManager(orgId, orgOwner1));
        assertTrue(jobFunds.canManageJobs(orgId, orgOwner1));
    }

    function test_isJobManager_nonExistentOrg_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        jobFunds.isJobManager(999, orgOwner1);
    }

    function test_canManageJobs_nonExistentOrg_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        jobFunds.canManageJobs(999, orgOwner1);
    }

    function test_orgAdminAuthorityIsScopedToOrg() public {
        uint256 otherOrgId = _createOrg(orgOwner2, "other.com");

        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, member1, true);

        assertTrue(jobFunds.canManageJobs(orgId, member1));
        assertFalse(jobFunds.canManageJobs(otherOrgId, member1));

        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, otherOrgId, member1));
        jobFunds.setJobManager(otherOrgId, member2, true);
    }

    function test_orgAdmin_canSetAndRevokeJobManager() public {
        vm.startPrank(orgOwner1);
        jobFunds.setJobManager(orgId, member1, true);

        assertTrue(jobFunds.isJobManager(orgId, member1));
        assertTrue(jobFunds.canManageJobs(orgId, member1));

        jobFunds.setJobManager(orgId, member1, false);
        vm.stopPrank();

        assertFalse(jobFunds.isJobManager(orgId, member1));
        assertFalse(jobFunds.canManageJobs(orgId, member1));
    }

    function test_delegatedOrgAdmin_canSetAndRevokeJobManager() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, member1, true);

        vm.startPrank(member1);
        jobFunds.setJobManager(orgId, member2, true);

        assertTrue(jobFunds.isJobManager(orgId, member2));
        assertTrue(jobFunds.canManageJobs(orgId, member2));

        jobFunds.setJobManager(orgId, member2, false);
        vm.stopPrank();

        assertFalse(jobFunds.isJobManager(orgId, member2));
        assertFalse(jobFunds.canManageJobs(orgId, member2));
    }

    function test_setJobManager_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IJobFunds.JobManagerUpdated(orgId, member1, true, orgOwner1, true);

        vm.prank(orgOwner1);
        jobFunds.setJobManager(orgId, member1, true);
    }

    function test_setJobManager_existingManagerIsNoOp() public {
        vm.prank(orgOwner1);
        jobFunds.setJobManager(orgId, member1, true);

        assertTrue(jobFunds.isJobManager(orgId, member1));
        assertTrue(jobFunds.canManageJobs(orgId, member1));

        vm.expectEmit(true, true, true, true, address(jobFunds));
        emit IJobFunds.JobManagerUpdated(orgId, member1, true, orgOwner1, false);

        vm.prank(orgOwner1);
        jobFunds.setJobManager(orgId, member1, true);

        assertTrue(jobFunds.isJobManager(orgId, member1));
        assertTrue(jobFunds.canManageJobs(orgId, member1));
    }

    function test_setJobManager_revokingNonManagerIsNoOp() public {
        assertFalse(jobFunds.isJobManager(orgId, member1));
        assertFalse(jobFunds.canManageJobs(orgId, member1));

        vm.expectEmit(true, true, true, true, address(jobFunds));
        emit IJobFunds.JobManagerUpdated(orgId, member1, false, orgOwner1, false);

        vm.prank(orgOwner1);
        jobFunds.setJobManager(orgId, member1, false);

        assertFalse(jobFunds.isJobManager(orgId, member1));
        assertFalse(jobFunds.canManageJobs(orgId, member1));
    }

    function test_nonOrgAdmin_cannotSetJobManager() public {
        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, orgId, member1));
        jobFunds.setJobManager(orgId, member2, true);
    }

    function test_jobManager_cannotSetOrRevokeJobManagers() public {
        vm.prank(orgOwner1);
        jobFunds.setJobManager(orgId, member1, true);

        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, orgId, member1));
        jobFunds.setJobManager(orgId, member2, true);
    }

    function test_zeroAddressRoleTargets_revert() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        jobFunds.setJobManager(orgId, address(0), true);
    }

    function test_orgAdminDoesNotAuthorizeDepositOrWithdraw() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, member1, true);

        vm.startPrank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, member1));
        jobFunds.depositWithAuthorization(orgId, 100_000_000, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, member1));
        jobFunds.withdraw(orgId, 1);
        vm.stopPrank();
    }

    function test_jobManagerDoesNotAuthorizeDepositOrWithdraw() public {
        vm.prank(orgOwner1);
        jobFunds.setJobManager(orgId, member1, true);

        vm.startPrank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, member1));
        jobFunds.depositWithAuthorization(orgId, 100_000_000, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, member1));
        jobFunds.withdraw(orgId, 1);
        vm.stopPrank();
    }
}
