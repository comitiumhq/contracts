// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {IResponseCommitment, CommitmentView} from "../../src/interfaces/IResponseCommitment.sol";
import {CommitmentStatus} from "../../src/types/CommitmentTypes.sol";
import {FeeTier, CommitmentConfig} from "../../src/types/ConfigTypes.sol";
import {Errors} from "../../src/Errors.sol";
import {BASIS_POINTS} from "../../src/Constants.sol";

/// @notice Simple ERC20 mock for rescue tests with a different token
contract MockToken is ERC20 {
    constructor() ERC20("Mock Token", "MCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title ConfigAndRescueTest
/// @notice Tests for admin config functions, rescueTokens, and protocol-role edge cases
contract ConfigAndRescueTest is ResponseCommitmentTestBase {
    function _buildV2Config() internal pure returns (CommitmentConfig memory) {
        CommitmentConfig memory config = _defaultCommitmentConfig();
        config.softSlashing.rate95 = 300;
        config.harshSlashing.rate95 = 300;

        return config;
    }

    function test_setCommitmentConfig_emitsEvent() public {
        CommitmentConfig memory v2Config = _buildV2Config();
        FeeTier[] memory tiers = _defaultFeeTiers();

        vm.expectEmit(true, true, true, true);
        emit IResponseCommitment.CommitmentConfigUpdated(2, v2Config, tiers);

        vm.prank(owner);
        responseCommitment.setCommitmentConfig(v2Config, tiers);
    }

    function test_setCommitmentConfig_notOwner_reverts() public {
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        responseCommitment.setCommitmentConfig(_buildV2Config(), _defaultFeeTiers());
    }

    function test_setCommitmentConfig_invalidMinStake_reverts() public {
        CommitmentConfig memory config = _defaultCommitmentConfig();
        config.minStake = 49_999_999; // below MIN_STAKE_LOWER ($50)

        vm.prank(owner);
        vm.expectPartialRevert(Errors.ConfigValueTooLow.selector);
        responseCommitment.setCommitmentConfig(config, _defaultFeeTiers());
    }

    function test_setCommitmentConfig_invalidFeeTierOrdering_reverts() public {
        FeeTier[] memory tiers = _defaultFeeTiers();
        tiers[1].feeBps = tiers[0].feeBps - 1;

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidTierOrdering.selector);
        responseCommitment.setCommitmentConfig(_defaultCommitmentConfig(), tiers);
    }

    function test_setCommitmentConfig_invalidSlashingOrdering_reverts() public {
        CommitmentConfig memory config = _defaultCommitmentConfig();
        config.softSlashing.rate95 = 600;

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidSlashingOrdering.selector);
        responseCommitment.setCommitmentConfig(config, _defaultFeeTiers());
    }

    function test_configVersionLocking_commitmentUsesCreationTimeConfig() public {
        uint256 commitmentId = _activateCommitment(0);

        vm.prank(owner);
        responseCommitment.setCommitmentConfig(_buildV2Config(), _defaultFeeTiers());

        assertEq(responseCommitment.currentConfigVersion(), 2);

        _stopCommitment(commitmentId);

        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _settleCommitment(commitmentId, 20, 20, 19);

        uint256 v1SlashRate = 200;
        uint256 expectedSlash = (EMPLOYER_STAKE * v1SlashRate) / BASIS_POINTS;

        uint256 orgBalanceAfter = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 actualSlash = orgBalanceBefore - orgBalanceAfter;
        assertEq(actualSlash, expectedSlash, "Slashing should use v1 config rate95=200, not v2's 300");

        uint256 v2SlashWouldBe = (EMPLOYER_STAKE * 300) / BASIS_POINTS;
        assertTrue(actualSlash != v2SlashWouldBe, "Slashing should NOT use v2 config");
    }

    function test_configVersionLocking_newCommitmentUsesNewConfig() public {
        CommitmentConfig memory v2Config = _defaultCommitmentConfig();
        v2Config.minStake = 200_000_000; // $200 instead of $50

        vm.prank(owner);
        responseCommitment.setCommitmentConfig(v2Config, _defaultFeeTiers());

        uint256 commitmentId = _activateCommitment(0);

        CommitmentView memory commitment = responseCommitment.commitment(commitmentId);
        assertEq(commitment.creator, employer);
        assertEq(uint8(commitment.status), uint8(CommitmentStatus.Active));
    }

    function test_getCommitmentConfig_returnsCorrectVersion() public {
        CommitmentConfig memory v1 = responseCommitment.commitmentConfig(1);
        assertEq(v1.softSlashing.rate95, 200, "v1 rate95 should be 200");

        CommitmentConfig memory v2Config = _buildV2Config();
        vm.prank(owner);
        responseCommitment.setCommitmentConfig(v2Config, _defaultFeeTiers());

        CommitmentConfig memory v2 = responseCommitment.commitmentConfig(2);
        assertEq(v2.softSlashing.rate95, 300, "v2 rate95 should be 300");

        CommitmentConfig memory v1Again = responseCommitment.commitmentConfig(1);
        assertEq(v1Again.softSlashing.rate95, 200, "v1 should still be 200");
    }

    function test_rescueTokens_otherToken_rescuesFullBalance() public {
        MockToken mockToken = new MockToken();

        uint256 amount = 1_000_000_000; // 1000 tokens
        mockToken.mint(address(responseCommitment), amount);

        assertEq(mockToken.balanceOf(address(responseCommitment)), amount);

        address rescueTo = makeAddr("rescueRecipient");
        vm.prank(owner);
        responseCommitment.rescueTokens(address(mockToken), rescueTo, amount);

        assertEq(mockToken.balanceOf(rescueTo), amount);
        assertEq(mockToken.balanceOf(address(responseCommitment)), 0);
    }

    function test_rescueTokens_usdc_rescuesFullBalance() public {
        uint256 amount = 10_000_000;
        address rescueTo = makeAddr("rescueRecipient");
        usdc.mint(address(responseCommitment), amount);

        vm.prank(owner);
        responseCommitment.rescueTokens(address(usdc), rescueTo, amount);

        assertEq(usdc.balanceOf(rescueTo), amount);
        assertEq(usdc.balanceOf(address(responseCommitment)), 0);
    }

    function test_rescueTokens_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        responseCommitment.rescueTokens(address(usdc), address(0), 1);
    }

    function test_rescueTokens_notOwner_reverts() public {
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        responseCommitment.rescueTokens(address(usdc), makeAddr("to"), 1);
    }

    function test_rescueTokens_emitsEvent() public {
        uint256 amount = 10_000_000;
        usdc.mint(address(responseCommitment), amount);
        address rescueTo = makeAddr("rescueRecipient");

        vm.expectEmit(true, true, true, true);
        emit IResponseCommitment.TokensRescued(address(usdc), rescueTo, amount);

        vm.prank(owner);
        responseCommitment.rescueTokens(address(usdc), rescueTo, amount);
    }

    // ============ Protocol Role Edge Cases ============

    function test_removeOperator_lastOperator_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.CannotRemoveLastOperator.selector);
        responseCommitment.removeOperator(operator);
    }

    function test_addOperator_duplicate_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.OperatorAlreadyRegistered.selector, operator));
        responseCommitment.addOperator(operator);
    }

    function test_removeOperator_notOperator_reverts() public {
        address nonOperator = makeAddr("nonOperator");

        vm.prank(owner);
        vm.expectRevert(Errors.NotOperator.selector);
        responseCommitment.removeOperator(nonOperator);
    }

    function test_removeExecutor_lastExecutor_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.CannotRemoveLastExecutor.selector);
        responseCommitment.removeExecutor(executor);
    }

    function test_addExecutor_duplicate_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutorAlreadyRegistered.selector, executor));
        responseCommitment.addExecutor(executor);
    }

    function test_addExecutor_trustedForwarder_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, address(forwarder)));
        responseCommitment.addExecutor(address(forwarder));
    }

    function test_removeExecutor_notExecutor_reverts() public {
        address nonExecutor = makeAddr("nonExecutor");

        vm.prank(owner);
        vm.expectRevert(Errors.NotExecutor.selector);
        responseCommitment.removeExecutor(nonExecutor);
    }

    // ============ View Functions (Nonce / ApplicationId) ============

    function test_creationKeyNonce_consumed() public {
        uint256 expectedKeyNonce = _packKeyNonce(NONCE_SCOPE_COMMITMENT_ACTIVATION, 1);
        uint192 key = _authorizationKeyFromKeyNonce(expectedKeyNonce);

        assertEq(responseCommitment.nonces(operator, key), expectedKeyNonce);

        _activateCommitment(0);

        assertEq(responseCommitment.nonces(operator, key), expectedKeyNonce + 1);
    }

    function test_settleKeyNonce_consumed() public {
        uint256 commitmentId = _activateCommitment(0);
        _stopCommitment(commitmentId);
        uint256 expectedKeyNonce = _packKeyNonce(NONCE_SCOPE_COMMITMENT_SETTLEMENT, 1);
        uint192 key = _authorizationKeyFromKeyNonce(expectedKeyNonce);

        assertEq(responseCommitment.nonces(operator, key), expectedKeyNonce);

        _settleCommitment(commitmentId, 0, 0, 0);

        assertEq(responseCommitment.nonces(operator, key), expectedKeyNonce + 1);
    }

    function test_isApplicationIdUsed() public {
        _activateCommitment(0);

        bytes32 appId = _generateApplicationId(applicant1);
        assertFalse(responseCommitment.isApplicationIdUsed(appId));

        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signApplication(appId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);
        vm.prank(applicant1);
        responseCommitment.submitApplication(appId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature);

        assertTrue(responseCommitment.isApplicationIdUsed(appId));
    }
}
