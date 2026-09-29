// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OrgRegistry} from "../../src/OrgRegistry.sol";
import {Errors} from "../../src/Errors.sol";

import {OrgTestBase} from "../shared/OrgTestBase.sol";

contract OrgConstructorAndAccessTest is OrgTestBase {
    function test_constructor_zeroOwner_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OrgRegistry(address(0), address(forwarder), operator, executor);
    }

    function test_constructor_zeroOperator_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new OrgRegistry(contractOwner, address(forwarder), address(0), executor);
    }

    function test_constructor_zeroExecutor_reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new OrgRegistry(contractOwner, address(forwarder), operator, address(0));
    }

    function test_constructor_operatorExecutorOverlap_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, operator));
        new OrgRegistry(contractOwner, address(forwarder), operator, operator);
    }

    function test_constructor_trustedForwarderExecutor_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, address(forwarder)));
        new OrgRegistry(contractOwner, address(forwarder), operator, address(forwarder));
    }

    function testFuzz_nonOwner_cannotPause(address caller) public {
        vm.assume(caller != contractOwner);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        registry.pause();
    }

    function test_transferOwnership_twoStepTransfersOwnerAuthority() public {
        address newOwner = makeAddr("newRegistryOwner");

        vm.prank(contractOwner);
        registry.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", newOwner));
        registry.pause();

        vm.prank(newOwner);
        registry.acceptOwnership();

        vm.prank(newOwner);
        registry.pause();

        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", contractOwner));
        registry.unpause();

        vm.prank(newOwner);
        registry.unpause();

        assertEq(registry.owner(), newOwner);
        assertFalse(registry.paused());
    }

    function testFuzz_nonOwner_cannotAddCommitment(address caller) public {
        vm.assume(caller != contractOwner);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        commitmentFunds.registerResponseCommitment(makeAddr("fake"), 1);
    }
}
