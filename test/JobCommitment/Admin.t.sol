// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {Errors} from "../../src/Errors.sol";
import {OperatorAuthorizer} from "../../src/abstract/OperatorAuthorizer.sol";
import {ExecutorRegistry} from "../../src/abstract/ExecutorRegistry.sol";

/// @title AdminTest
/// @notice Tests protocol-role and ownership administration.
contract AdminTest is JobCommitmentTestBase {
    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.RenounceDisabled.selector);
        jobCommitment.renounceOwnership();

        assertEq(jobCommitment.owner(), owner);
    }

    function test_transferOwnership_twoStepStillWorks() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        jobCommitment.transferOwnership(newOwner);

        vm.prank(newOwner);
        jobCommitment.acceptOwnership();

        assertEq(jobCommitment.owner(), newOwner);
    }

    function test_addAndRemoveOperator() public {
        address newOperator = makeAddr("newOperator");

        vm.expectEmit(true, true, true, true);
        emit OperatorAuthorizer.OperatorUpdated(newOperator, true, owner);

        vm.prank(owner);
        jobCommitment.addOperator(newOperator);

        assertTrue(jobCommitment.isOperator(newOperator));

        vm.expectEmit(true, true, true, true);
        emit OperatorAuthorizer.OperatorUpdated(newOperator, false, owner);

        vm.prank(owner);
        jobCommitment.removeOperator(newOperator);

        assertFalse(jobCommitment.isOperator(newOperator));
        assertTrue(jobCommitment.isOperator(operator));
    }

    function test_addAndRemoveExecutor() public {
        address newExecutor = makeAddr("newExecutor");

        vm.expectEmit(true, true, true, true);
        emit ExecutorRegistry.ExecutorUpdated(newExecutor, true, owner);

        vm.prank(owner);
        jobCommitment.addExecutor(newExecutor);

        assertTrue(jobCommitment.isExecutor(newExecutor));

        vm.expectEmit(true, true, true, true);
        emit ExecutorRegistry.ExecutorUpdated(newExecutor, false, owner);

        vm.prank(owner);
        jobCommitment.removeExecutor(newExecutor);

        assertFalse(jobCommitment.isExecutor(newExecutor));
        assertTrue(jobCommitment.isExecutor(executor));
    }

    function test_addOperator_executorAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, executor));
        jobCommitment.addOperator(executor);
    }

    function test_addExecutor_operatorAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, operator));
        jobCommitment.addExecutor(operator);
    }

    function test_addProtocolRole_zeroAddress_reverts() public {
        vm.startPrank(owner);

        vm.expectRevert(Errors.ZeroAddress.selector);
        jobCommitment.addOperator(address(0));

        vm.expectRevert(Errors.ZeroAddress.selector);
        jobCommitment.addExecutor(address(0));

        vm.stopPrank();
    }

    function test_addProtocolRole_notOwner_reverts() public {
        vm.startPrank(employer);

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        jobCommitment.addOperator(makeAddr("newOperator"));

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        jobCommitment.addExecutor(makeAddr("newExecutor"));

        vm.stopPrank();
    }

    function test_protocolRoleViews_returnActiveAccounts() public {
        address newOperator = makeAddr("newOperator");
        address newExecutor = makeAddr("newExecutor");

        vm.startPrank(owner);
        jobCommitment.addOperator(newOperator);
        jobCommitment.addExecutor(newExecutor);
        vm.stopPrank();

        address[] memory operators = jobCommitment.operators();
        address[] memory executors = jobCommitment.executors();

        assertEq(operators.length, 2);
        assertEq(operators[0], operator);
        assertEq(operators[1], newOperator);
        assertEq(executors.length, 2);
        assertEq(executors[0], executor);
        assertEq(executors[1], newExecutor);
    }
}
