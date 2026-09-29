// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {ICommitmentFunds} from "../../src/interfaces/ICommitmentFunds.sol";
import {Errors} from "../../src/Errors.sol";

import {OrgTestBase} from "../shared/OrgTestBase.sol";

contract CommitmentFundsAuthorityTest is OrgTestBase {
    uint256 orgId;

    function setUp() public override {
        super.setUp();
        orgId = _createOrg(orgOwner1, "test.com");
        _fundAndDeposit(orgId, orgOwner1, 1_000_000_000);
    }

    function test_creatorHasImplicitOrgAdminCommitmentManagementAuthority() public view {
        assertTrue(registry.isOrgAdmin(orgId, orgOwner1));
        assertFalse(commitmentFunds.isCommitmentManager(orgId, orgOwner1));
        assertTrue(commitmentFunds.canManageCommitments(orgId, orgOwner1));
    }

    function test_isCommitmentManager_nonExistentOrg_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        commitmentFunds.isCommitmentManager(999, orgOwner1);
    }

    function test_canManageCommitments_nonExistentOrg_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.OrgNotFound.selector, 999));
        commitmentFunds.canManageCommitments(999, orgOwner1);
    }

    function test_orgAdminAuthorityIsScopedToOrg() public {
        uint256 otherOrgId = _createOrg(orgOwner2, "other.com");

        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, member1, true);

        assertTrue(commitmentFunds.canManageCommitments(orgId, member1));
        assertFalse(commitmentFunds.canManageCommitments(otherOrgId, member1));

        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, otherOrgId, member1));
        commitmentFunds.setCommitmentManager(otherOrgId, member2, true);
    }

    function test_orgAdmin_canSetAndRevokeCommitmentManager() public {
        vm.startPrank(orgOwner1);
        commitmentFunds.setCommitmentManager(orgId, member1, true);

        assertTrue(commitmentFunds.isCommitmentManager(orgId, member1));
        assertTrue(commitmentFunds.canManageCommitments(orgId, member1));

        commitmentFunds.setCommitmentManager(orgId, member1, false);
        vm.stopPrank();

        assertFalse(commitmentFunds.isCommitmentManager(orgId, member1));
        assertFalse(commitmentFunds.canManageCommitments(orgId, member1));
    }

    function test_delegatedOrgAdmin_canSetAndRevokeCommitmentManager() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, member1, true);

        vm.startPrank(member1);
        commitmentFunds.setCommitmentManager(orgId, member2, true);

        assertTrue(commitmentFunds.isCommitmentManager(orgId, member2));
        assertTrue(commitmentFunds.canManageCommitments(orgId, member2));

        commitmentFunds.setCommitmentManager(orgId, member2, false);
        vm.stopPrank();

        assertFalse(commitmentFunds.isCommitmentManager(orgId, member2));
        assertFalse(commitmentFunds.canManageCommitments(orgId, member2));
    }

    function test_setCommitmentManager_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ICommitmentFunds.CommitmentManagerUpdated(orgId, member1, true, orgOwner1, true);

        vm.prank(orgOwner1);
        commitmentFunds.setCommitmentManager(orgId, member1, true);
    }

    function test_setCommitmentManager_existingManagerIsNoOp() public {
        vm.prank(orgOwner1);
        commitmentFunds.setCommitmentManager(orgId, member1, true);

        assertTrue(commitmentFunds.isCommitmentManager(orgId, member1));
        assertTrue(commitmentFunds.canManageCommitments(orgId, member1));

        vm.expectEmit(true, true, true, true, address(commitmentFunds));
        emit ICommitmentFunds.CommitmentManagerUpdated(orgId, member1, true, orgOwner1, false);

        vm.prank(orgOwner1);
        commitmentFunds.setCommitmentManager(orgId, member1, true);

        assertTrue(commitmentFunds.isCommitmentManager(orgId, member1));
        assertTrue(commitmentFunds.canManageCommitments(orgId, member1));
    }

    function test_setCommitmentManager_revokingNonManagerIsNoOp() public {
        assertFalse(commitmentFunds.isCommitmentManager(orgId, member1));
        assertFalse(commitmentFunds.canManageCommitments(orgId, member1));

        vm.expectEmit(true, true, true, true, address(commitmentFunds));
        emit ICommitmentFunds.CommitmentManagerUpdated(orgId, member1, false, orgOwner1, false);

        vm.prank(orgOwner1);
        commitmentFunds.setCommitmentManager(orgId, member1, false);

        assertFalse(commitmentFunds.isCommitmentManager(orgId, member1));
        assertFalse(commitmentFunds.canManageCommitments(orgId, member1));
    }

    function test_nonOrgAdmin_cannotSetCommitmentManager() public {
        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, orgId, member1));
        commitmentFunds.setCommitmentManager(orgId, member2, true);
    }

    function test_commitmentManager_cannotSetOrRevokeCommitmentManagers() public {
        vm.prank(orgOwner1);
        commitmentFunds.setCommitmentManager(orgId, member1, true);

        vm.prank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgAdmin.selector, orgId, member1));
        commitmentFunds.setCommitmentManager(orgId, member2, true);
    }

    function test_zeroAddressRoleTargets_revert() public {
        vm.prank(orgOwner1);
        vm.expectRevert(Errors.ZeroAddress.selector);
        commitmentFunds.setCommitmentManager(orgId, address(0), true);
    }

    function test_orgAdminDoesNotAuthorizeDepositOrWithdraw() public {
        vm.prank(orgOwner1);
        registry.setOrgAdmin(orgId, member1, true);

        vm.startPrank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, member1));
        commitmentFunds.depositWithAuthorization(orgId, 100_000_000, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, member1));
        commitmentFunds.withdraw(orgId, 1);
        vm.stopPrank();
    }

    function test_commitmentManagerDoesNotAuthorizeDepositOrWithdraw() public {
        vm.prank(orgOwner1);
        commitmentFunds.setCommitmentManager(orgId, member1, true);

        vm.startPrank(member1);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, member1));
        commitmentFunds.depositWithAuthorization(orgId, 100_000_000, 0, block.timestamp + 1 hours, bytes32(0), 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(Errors.NotOrgTreasury.selector, orgId, member1));
        commitmentFunds.withdraw(orgId, 1);
        vm.stopPrank();
    }
}
