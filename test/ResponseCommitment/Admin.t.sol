// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {OperatorAuthorizer} from "../../src/abstract/OperatorAuthorizer.sol";
import {ExecutorRegistry} from "../../src/abstract/ExecutorRegistry.sol";

/// @title AdminTest
/// @notice Tests protocol-role and ownership administration.
contract AdminTest is ResponseCommitmentTestBase {
    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.RenounceDisabled.selector);
        responseCommitment.renounceOwnership();

        assertEq(responseCommitment.owner(), owner);
    }

    function test_transferOwnership_twoStepStillWorks() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        responseCommitment.transferOwnership(newOwner);

        vm.prank(newOwner);
        responseCommitment.acceptOwnership();

        assertEq(responseCommitment.owner(), newOwner);
    }

    function test_addAndRemoveOperator() public {
        address newOperator = makeAddr("newOperator");

        vm.expectEmit(true, true, true, true);
        emit OperatorAuthorizer.OperatorUpdated(newOperator, true, owner);

        vm.prank(owner);
        responseCommitment.addOperator(newOperator);

        assertTrue(responseCommitment.isOperator(newOperator));

        vm.expectEmit(true, true, true, true);
        emit OperatorAuthorizer.OperatorUpdated(newOperator, false, owner);

        vm.prank(owner);
        responseCommitment.removeOperator(newOperator);

        assertFalse(responseCommitment.isOperator(newOperator));
        assertTrue(responseCommitment.isOperator(operator));
    }

    function test_addAndRemoveExecutor() public {
        address newExecutor = makeAddr("newExecutor");

        vm.expectEmit(true, true, true, true);
        emit ExecutorRegistry.ExecutorUpdated(newExecutor, true, owner);

        vm.prank(owner);
        responseCommitment.addExecutor(newExecutor);

        assertTrue(responseCommitment.isExecutor(newExecutor));

        vm.expectEmit(true, true, true, true);
        emit ExecutorRegistry.ExecutorUpdated(newExecutor, false, owner);

        vm.prank(owner);
        responseCommitment.removeExecutor(newExecutor);

        assertFalse(responseCommitment.isExecutor(newExecutor));
        assertTrue(responseCommitment.isExecutor(executor));
    }

    function test_addOperator_executorAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, executor));
        responseCommitment.addOperator(executor);
    }

    function test_addExecutor_operatorAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, operator));
        responseCommitment.addExecutor(operator);
    }

    function test_addProtocolRole_zeroAddress_reverts() public {
        vm.startPrank(owner);

        vm.expectRevert(Errors.ZeroAddress.selector);
        responseCommitment.addOperator(address(0));

        vm.expectRevert(Errors.ZeroAddress.selector);
        responseCommitment.addExecutor(address(0));

        vm.stopPrank();
    }

    function test_addProtocolRole_notOwner_reverts() public {
        vm.startPrank(employer);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        responseCommitment.addOperator(makeAddr("newOperator"));

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        responseCommitment.addExecutor(makeAddr("newExecutor"));

        vm.stopPrank();
    }

    function test_protocolRoleViews_returnActiveAccounts() public {
        address newOperator = makeAddr("newOperator");
        address newExecutor = makeAddr("newExecutor");

        vm.startPrank(owner);
        responseCommitment.addOperator(newOperator);
        responseCommitment.addExecutor(newExecutor);
        vm.stopPrank();

        address[] memory operators = responseCommitment.operators();
        address[] memory executors = responseCommitment.executors();

        assertEq(operators.length, 2);
        assertEq(operators[0], operator);
        assertEq(operators[1], newOperator);
        assertEq(executors.length, 2);
        assertEq(executors[0], executor);
        assertEq(executors[1], newExecutor);
    }
}
