// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {IJobCommitment, JobView} from "../../src/interfaces/IJobCommitment.sol";
import {JobStatus} from "../../src/types/JobTypes.sol";
import {FeeTier, JobConfig} from "../../src/types/ConfigTypes.sol";
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
contract ConfigAndRescueTest is JobCommitmentTestBase {
    function _buildV2Config() internal pure returns (JobConfig memory) {
        JobConfig memory config = _defaultJobConfig();
        config.softSlashing.rate95 = 300;
        config.harshSlashing.rate95 = 300;

        return config;
    }

    function test_setJobConfig_updatesVersion() public {
        assertEq(jobCommitment.currentConfigVersion(), 1);

        vm.prank(owner);
        jobCommitment.setJobConfig(_buildV2Config(), _defaultFeeTiers());

        assertEq(jobCommitment.currentConfigVersion(), 2);
    }

    function test_setJobConfig_emitsEvent() public {
        JobConfig memory v2Config = _buildV2Config();
        FeeTier[] memory tiers = _defaultFeeTiers();

        vm.expectEmit(true, true, true, true);
        emit IJobCommitment.JobConfigUpdated(2, v2Config, tiers);

        vm.prank(owner);
        jobCommitment.setJobConfig(v2Config, tiers);
    }

    function test_setJobConfig_notOwner_reverts() public {
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        jobCommitment.setJobConfig(_buildV2Config(), _defaultFeeTiers());
    }

    function test_setJobConfig_invalidMinStake_reverts() public {
        JobConfig memory config = _defaultJobConfig();
        config.minStake = 49_999_999; // below MIN_STAKE_LOWER ($50)

        vm.prank(owner);
        vm.expectPartialRevert(Errors.ConfigValueTooLow.selector);
        jobCommitment.setJobConfig(config, _defaultFeeTiers());
    }

    function test_setJobConfig_invalidFeeTierOrdering_reverts() public {
        FeeTier[] memory tiers = _defaultFeeTiers();
        tiers[1].feeBps = tiers[0].feeBps - 1;

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidTierOrdering.selector);
        jobCommitment.setJobConfig(_defaultJobConfig(), tiers);
    }

    function test_setJobConfig_invalidSlashingOrdering_reverts() public {
        JobConfig memory config = _defaultJobConfig();
        config.softSlashing.rate95 = 600;

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidSlashingOrdering.selector);
        jobCommitment.setJobConfig(config, _defaultFeeTiers());
    }

    function test_configVersionLocking_jobUsesCreationTimeConfig() public {
        uint256 jobId = _publishJob(0);

        vm.prank(owner);
        jobCommitment.setJobConfig(_buildV2Config(), _defaultFeeTiers());

        assertEq(jobCommitment.currentConfigVersion(), 2);

        _unpublishJob(jobId);

        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        _closeJob(jobId, 20, 20, 19);

        uint256 v1SlashRate = 200;
        uint256 expectedSlash = (EMPLOYER_STAKE * v1SlashRate) / BASIS_POINTS;

        uint256 orgBalanceAfter = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 actualSlash = orgBalanceBefore - orgBalanceAfter;
        assertEq(actualSlash, expectedSlash, "Slashing should use v1 config rate95=200, not v2's 300");

        uint256 v2SlashWouldBe = (EMPLOYER_STAKE * 300) / BASIS_POINTS;
        assertTrue(actualSlash != v2SlashWouldBe, "Slashing should NOT use v2 config");
    }

    function test_configVersionLocking_newJobUsesNewConfig() public {
        JobConfig memory v2Config = _defaultJobConfig();
        v2Config.minStake = 200_000_000; // $200 instead of $50

        vm.prank(owner);
        jobCommitment.setJobConfig(v2Config, _defaultFeeTiers());

        uint256 jobId = _publishJob(0);

        JobView memory job = jobCommitment.job(jobId);
        assertEq(job.creator, employer);
        assertEq(uint8(job.status), uint8(JobStatus.Published));
    }

    function test_getCurrentConfigVersion_returnsCorrect() public {
        assertEq(jobCommitment.currentConfigVersion(), 1);

        vm.prank(owner);
        jobCommitment.setJobConfig(_buildV2Config(), _defaultFeeTiers());

        assertEq(jobCommitment.currentConfigVersion(), 2);
    }

    function test_getJobConfig_returnsCorrectVersion() public {
        JobConfig memory v1 = jobCommitment.jobConfig(1);
        assertEq(v1.softSlashing.rate95, 200, "v1 rate95 should be 200");

        JobConfig memory v2Config = _buildV2Config();
        vm.prank(owner);
        jobCommitment.setJobConfig(v2Config, _defaultFeeTiers());

        JobConfig memory v2 = jobCommitment.jobConfig(2);
        assertEq(v2.softSlashing.rate95, 300, "v2 rate95 should be 300");

        JobConfig memory v1Again = jobCommitment.jobConfig(1);
        assertEq(v1Again.softSlashing.rate95, 200, "v1 should still be 200");
    }

    function test_rescueTokens_otherToken_rescuesFullBalance() public {
        MockToken mockToken = new MockToken();

        uint256 amount = 1_000_000_000; // 1000 tokens
        mockToken.mint(address(jobCommitment), amount);

        assertEq(mockToken.balanceOf(address(jobCommitment)), amount);

        address rescueTo = makeAddr("rescueRecipient");
        vm.prank(owner);
        jobCommitment.rescueTokens(address(mockToken), rescueTo, amount);

        assertEq(mockToken.balanceOf(rescueTo), amount);
        assertEq(mockToken.balanceOf(address(jobCommitment)), 0);
    }

    function test_rescueTokens_usdc_rescuesFullBalance() public {
        uint256 amount = 10_000_000;
        address rescueTo = makeAddr("rescueRecipient");
        usdc.mint(address(jobCommitment), amount);

        vm.prank(owner);
        jobCommitment.rescueTokens(address(usdc), rescueTo, amount);

        assertEq(usdc.balanceOf(rescueTo), amount);
        assertEq(usdc.balanceOf(address(jobCommitment)), 0);
    }

    function test_rescueTokens_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.ZeroAddress.selector);
        jobCommitment.rescueTokens(address(usdc), address(0), 1);
    }

    function test_rescueTokens_notOwner_reverts() public {
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        jobCommitment.rescueTokens(address(usdc), makeAddr("to"), 1);
    }

    function test_rescueTokens_emitsEvent() public {
        uint256 amount = 10_000_000;
        usdc.mint(address(jobCommitment), amount);
        address rescueTo = makeAddr("rescueRecipient");

        vm.expectEmit(true, true, true, true);
        emit IJobCommitment.TokensRescued(address(usdc), rescueTo, amount);

        vm.prank(owner);
        jobCommitment.rescueTokens(address(usdc), rescueTo, amount);
    }

    // ============ Protocol Role Edge Cases ============

    function test_removeOperator_lastOperator_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.CannotRemoveLastOperator.selector);
        jobCommitment.removeOperator(operator);
    }

    function test_addOperator_duplicate_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.OperatorAlreadyRegistered.selector, operator));
        jobCommitment.addOperator(operator);
    }

    function test_removeOperator_notOperator_reverts() public {
        address nonOperator = makeAddr("nonOperator");

        vm.prank(owner);
        vm.expectRevert(Errors.NotOperator.selector);
        jobCommitment.removeOperator(nonOperator);
    }

    function test_removeExecutor_lastExecutor_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Errors.CannotRemoveLastExecutor.selector);
        jobCommitment.removeExecutor(executor);
    }

    function test_addExecutor_duplicate_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ExecutorAlreadyRegistered.selector, executor));
        jobCommitment.addExecutor(executor);
    }

    function test_addExecutor_trustedForwarder_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ProtocolRoleConflict.selector, address(forwarder)));
        jobCommitment.addExecutor(address(forwarder));
    }

    function test_removeExecutor_notExecutor_reverts() public {
        address nonExecutor = makeAddr("nonExecutor");

        vm.prank(owner);
        vm.expectRevert(Errors.NotExecutor.selector);
        jobCommitment.removeExecutor(nonExecutor);
    }

    // ============ View Functions (Nonce / ApplicationId) ============

    function test_creationKeyNonce_consumed() public {
        uint256 expectedKeyNonce = _packKeyNonce(NONCE_SCOPE_JOB_PUBLISH, 1);
        uint192 key = _authorizationKeyFromKeyNonce(expectedKeyNonce);

        assertEq(jobCommitment.nonces(operator, key), expectedKeyNonce);

        _publishJob(0);

        assertEq(jobCommitment.nonces(operator, key), expectedKeyNonce + 1);
    }

    function test_closeKeyNonce_consumed() public {
        uint256 jobId = _publishJob(0);
        _unpublishJob(jobId);
        uint256 expectedKeyNonce = _packKeyNonce(NONCE_SCOPE_JOB_CLOSE, 1);
        uint192 key = _authorizationKeyFromKeyNonce(expectedKeyNonce);

        assertEq(jobCommitment.nonces(operator, key), expectedKeyNonce);

        _closeJob(jobId, 0, 0, 0);

        assertEq(jobCommitment.nonces(operator, key), expectedKeyNonce + 1);
    }

    function test_isApplicationIdUsed() public {
        _publishJob(0);

        bytes32 appId = _generateApplicationId(applicant1);
        assertFalse(jobCommitment.isApplicationIdUsed(appId));

        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature = _signApplication(appId, applicant1, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);
        vm.prank(applicant1);
        jobCommitment.submitApplication(appId, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature);

        assertTrue(jobCommitment.isApplicationIdUsed(appId));
    }
}
