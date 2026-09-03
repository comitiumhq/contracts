// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ValidateDeployment, ParsedDeploymentCatalog, DeploymentRoleMissing} from "../script/ValidateDeployment.s.sol";
import {DeploymentJobCommitment} from "../script/Base.s.sol";

contract ProtocolRolesMock {
    address[] private _operators;
    address[] private _executors;

    constructor(address operator, address executor) {
        if (operator != address(0)) _operators.push(operator);
        if (executor != address(0)) _executors.push(executor);
    }

    function operators() external view returns (address[] memory) {
        return _operators;
    }

    function executors() external view returns (address[] memory) {
        return _executors;
    }
}

contract ValidateDeploymentHarness is ValidateDeployment {
    function assertConfiguredRoles(ParsedDeploymentCatalog memory catalog) external view {
        _assertConfiguredRoles(catalog);
    }
}

contract ValidateDeploymentTest is Test {
    ValidateDeploymentHarness private harness;
    address private operator = makeAddr("operator");
    address private executor = makeAddr("executor");

    function setUp() public {
        harness = new ValidateDeploymentHarness();
        vm.setEnv("OPERATOR_ADDRESS", vm.toString(operator));
        vm.setEnv("RELAYER_ADDRESS", vm.toString(executor));
    }

    function test_configuredRoles_checksEveryCataloguedCommitment() public {
        ProtocolRolesMock registry = new ProtocolRolesMock(operator, address(0));
        ProtocolRolesMock firstCommitment = new ProtocolRolesMock(operator, executor);
        ProtocolRolesMock secondCommitment = new ProtocolRolesMock(operator, address(0));

        ParsedDeploymentCatalog memory catalog;
        catalog.orgRegistry.address_ = address(registry);
        catalog.jobCommitments = new DeploymentJobCommitment[](2);
        catalog.jobCommitments[0].address_ = address(firstCommitment);
        catalog.jobCommitments[1].address_ = address(secondCommitment);

        vm.expectRevert(abi.encodeWithSelector(DeploymentRoleMissing.selector, "JobCommitment executor", executor));
        harness.assertConfiguredRoles(catalog);
    }
}
