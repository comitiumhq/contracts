// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {OrgTestBase} from "../shared/OrgTestBase.sol";
import {IOrgRegistry} from "../../src/interfaces/IOrgRegistry.sol";
import {Errors} from "../../src/Errors.sol";
import {USDC} from "../mocks/USDC.sol";

/// @title OrgControlsAndRescueTest
/// @notice Tests token rescue and operator edge cases.
contract OrgControlsAndRescueTest is OrgTestBase {
    function setUp() public override {
        super.setUp();
        _createOrg(orgOwner1, "test.com");
    }

    function test_rescueTokens_rescuesTokenBalance() public {
        uint256 amount = 500_000;
        usdc.mint(address(registry), amount);

        address rescueTo = makeAddr("rescueRecipient");
        uint256 balanceBefore = usdc.balanceOf(rescueTo);

        vm.prank(contractOwner);
        registry.rescueTokens(address(usdc), rescueTo, amount);

        assertEq(usdc.balanceOf(rescueTo) - balanceBefore, amount);
    }

    function test_rescueTokens_exceedsBalance_reverts() public {
        uint256 balance = 500_000;
        usdc.mint(address(registry), balance);

        uint256 requested = balance + 1;
        vm.prank(contractOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(registry), balance, requested
            )
        );
        registry.rescueTokens(address(usdc), makeAddr("rescueRecipient"), requested);
    }

    function test_rescueTokens_noBalance_reverts() public {
        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(registry), 0, 1));
        registry.rescueTokens(address(usdc), makeAddr("rescueRecipient"), 1);
    }

    function test_rescueTokens_otherToken_rescuesFullBalance() public {
        USDC otherToken = new USDC();
        uint256 amount = 1_000_000;
        otherToken.mint(address(registry), amount);

        address rescueTo = makeAddr("rescueRecipient");

        vm.prank(contractOwner);
        registry.rescueTokens(address(otherToken), rescueTo, amount);

        assertEq(otherToken.balanceOf(rescueTo), amount);
        assertEq(otherToken.balanceOf(address(registry)), 0);
    }

    function test_rescueTokens_zeroAddress_reverts() public {
        usdc.mint(address(registry), 1_000_000);

        vm.prank(contractOwner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.rescueTokens(address(usdc), address(0), 1);
    }

    function test_rescueTokens_notOwner_reverts() public {
        usdc.mint(address(registry), 1_000_000);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        registry.rescueTokens(address(usdc), makeAddr("rescueRecipient"), 1);
    }

    function test_rescueTokens_emitsEvent() public {
        uint256 amount = 500_000;
        usdc.mint(address(registry), amount);

        address rescueTo = makeAddr("rescueRecipient");

        vm.expectEmit(true, true, true, true);
        emit IOrgRegistry.TokensRescued(address(usdc), rescueTo, amount);

        vm.prank(contractOwner);
        registry.rescueTokens(address(usdc), rescueTo, amount);
    }

    function test_removeOperator_lastOperator_reverts() public {
        vm.prank(contractOwner);
        vm.expectRevert(Errors.CannotRemoveLastOperator.selector);
        registry.removeOperator(operator);
    }

    function test_addOperator_duplicate_reverts() public {
        vm.prank(contractOwner);
        vm.expectRevert(abi.encodeWithSelector(Errors.OperatorAlreadyRegistered.selector, operator));
        registry.addOperator(operator);
    }

    function test_removeOperator_notOperator_reverts() public {
        address nobody = makeAddr("nobody");

        vm.prank(contractOwner);
        vm.expectRevert(Errors.NotOperator.selector);
        registry.removeOperator(nobody);
    }

    function test_domainKeyNonce_afterCreateOrg() public view {
        uint256 keyNonce = _packKeyNonce(NONCE_SCOPE_DOMAIN_VERIFICATION, 1);
        uint192 key = _authorizationKeyFromKeyNonce(keyNonce);

        assertEq(registry.nonces(operator, key), keyNonce + 1);
    }
}
