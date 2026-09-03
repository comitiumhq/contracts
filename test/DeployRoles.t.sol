// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {Deploy, ProtocolRolesOverlap, ZeroDeployAddress} from "../script/Deploy.s.sol";

contract DeployRolesHarness is Deploy {
    function singleAddressSet(address account) external pure returns (address[] memory) {
        return _singleAddressSet(account);
    }

    function validateProtocolRoles(address operator, address executor) external pure {
        _validateProtocolRoles(operator, executor);
    }
}

contract DeployRolesTest is Test {
    DeployRolesHarness private harness;

    function setUp() public {
        harness = new DeployRolesHarness();
    }

    function test_singleAddressSet_returnsAccount() public {
        address account = makeAddr("account");

        address[] memory accounts = harness.singleAddressSet(account);

        assertEq(accounts.length, 1);
        assertEq(accounts[0], account);
    }

    function test_validateProtocolRoles_acceptsDistinctAccounts() public {
        harness.validateProtocolRoles(makeAddr("operator"), makeAddr("executor"));
    }

    function test_validateProtocolRoles_revertsOnOverlap() public {
        address account = makeAddr("sharedRole");

        vm.expectRevert(abi.encodeWithSelector(ProtocolRolesOverlap.selector, account));
        harness.validateProtocolRoles(account, account);
    }

    function test_validateProtocolRoles_revertsOnZeroOperator() public {
        vm.expectRevert(abi.encodeWithSelector(ZeroDeployAddress.selector, "OPERATOR_ADDRESS"));
        harness.validateProtocolRoles(address(0), makeAddr("executor"));
    }

    function test_validateProtocolRoles_revertsOnZeroExecutor() public {
        vm.expectRevert(abi.encodeWithSelector(ZeroDeployAddress.selector, "RELAYER_ADDRESS"));
        harness.validateProtocolRoles(makeAddr("operator"), address(0));
    }
}
