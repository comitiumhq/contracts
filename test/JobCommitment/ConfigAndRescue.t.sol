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
    // ============ Helpers ============

    /// @notice Build a valid v2 config with different softSlashing rates
    function _buildV2Config() internal pure returns (JobConfig memory) {
        JobConfig memory config = _defaultJobConfig();
        // Change softSlashing rate95 from 200 to 300 bps
        config.softSlashing.rate95 = 300;
        config.harshSlashing.rate95 = 300;

        return config;
    }

    // ============ setJobConfig Tests ============

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
        // harsh.rate95 (500) < soft.rate95 (600) -> invalid (harsh must >= soft)
        config.softSlashing.rate95 = 600;

        vm.prank(owner);
        vm.expectRevert(Errors.InvalidSlashingOrdering.selector);
        jobCommitment.setJobConfig(config, _defaultFeeTiers());
    }

    // ============ Config Version Locking Tests (Aave v4 pattern) ============

    function test_configVersionLocking_jobUsesCreationTimeConfig() public {
        // 1. Create job with v1 config (softSlashing.rate95 = 200 bps)
        uint256 jobId = _publishJob(0);

        // 2. Update to v2 config (softSlashing.rate95 = 300 bps)
        vm.prank(owner);
        jobCommitment.setJobConfig(_buildV2Config(), _defaultFeeTiers());

        // Verify v2 is now current
        assertEq(jobCommitment.currentConfigVersion(), 2);

        // 3. Apply to job, respond, close, close with 95% on-time rate
        //    Need 20 total, 19 on-time to get 95%
        bytes32[] memory appIds = new bytes32[](20);
        for (uint256 i = 0; i < 20; i++) {
            address applicant = makeAddr(string(abi.encodePacked("applicant_vl_", i)));
            _fundApplicant(applicant);
            appIds[i] = _applyToJob(applicant);
        }

        // Respond to all 20 (19 on-time, 1 late)
        for (uint256 i = 0; i < 19; i++) {
            _respondToApplication(appIds[i]);
        }

        // Respond late to the last one
        _respondToApplicationLate(appIds[19]);

        // Close the job
        _unpublishJob(jobId);

        // Get org balance before close
        uint256 orgBalanceBefore = _getOrgOperationalBalance(DEFAULT_ORG_ID);

        // Close with 95% on-time: 20 total, 20 responded, 19 on-time
        _closeJob(jobId, 20, 20, 19);

        // 4. Verify slashing used v1's rate95 (200 bps), NOT v2's (300 bps)
        //    v1 softSlashing.rate95 = 200 bps -> slashAmount = stake * 200 / 10000
        //    v2 softSlashing.rate95 = 300 bps -> slashAmount = stake * 300 / 10000
        uint256 v1SlashRate = 200; // v1 softSlashing.rate95
        uint256 expectedSlash = (EMPLOYER_STAKE * v1SlashRate) / BASIS_POINTS;

        // settleJob removes slashedAmount from jobFunds accounting
        // So orgBalanceBefore - orgBalanceAfter == slashedAmount
        uint256 orgBalanceAfter = _getOrgOperationalBalance(DEFAULT_ORG_ID);
        uint256 actualSlash = orgBalanceBefore - orgBalanceAfter;
        assertEq(actualSlash, expectedSlash, "Slashing should use v1 config rate95=200, not v2's 300");

        // Double-check: if v2 were used, slash would be 300 bps = 15M, not 10M
        uint256 v2SlashWouldBe = (EMPLOYER_STAKE * 300) / BASIS_POINTS;
        assertTrue(actualSlash != v2SlashWouldBe, "Slashing should NOT use v2 config");
    }

    function test_configVersionLocking_newJobUsesNewConfig() public {
        // Update to v2 config with higher minStake
        JobConfig memory v2Config = _defaultJobConfig();
        v2Config.minStake = 200_000_000; // $200 instead of $50

        vm.prank(owner);
        jobCommitment.setJobConfig(v2Config, _defaultFeeTiers());

        // Create a new job — should use v2 config
        // Stake 500 USDC (above new $200 min) should work
        uint256 jobId = _publishJob(0);

        // Verify the job was created (would revert if config mismatch)
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

        // v1 should still be accessible and unchanged
        JobConfig memory v1Again = jobCommitment.jobConfig(1);
        assertEq(v1Again.softSlashing.rate95, 200, "v1 should still be 200");
    }

    // ============ setApplicantStakeAmount Tests ============

    function test_setApplicantStakeAmount_updatesImmediately() public {
        vm.prank(owner);
        jobCommitment.setApplicantStakeAmount(7_000_000);

        assertEq(jobCommitment.applicantStakeAmount(), 7_000_000);
    }

    function test_setApplicantStakeAmount_emitsEvent() public {
        vm.expectEmit();
        emit IJobCommitment.ApplicantStakeAmountUpdated(7_000_000);

        vm.prank(owner);
        jobCommitment.setApplicantStakeAmount(7_000_000);
    }

    function test_setApplicantStakeAmount_notOwner_reverts() public {
        vm.prank(employer);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", employer));
        jobCommitment.setApplicantStakeAmount(7_000_000);
    }

    function test_setApplicantStakeAmount_noOp_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.ApplicantStakeAmountUnchanged.selector, APPLICANT_STAKE_96));
        jobCommitment.setApplicantStakeAmount(APPLICANT_STAKE_96);
    }

    function test_setApplicantStakeAmount_belowBound_reverts() public {
        vm.prank(owner);
        vm.expectPartialRevert(Errors.ConfigValueTooLow.selector);
        jobCommitment.setApplicantStakeAmount(999_999);
    }

    function test_setApplicantStakeAmount_aboveBound_reverts() public {
        vm.prank(owner);
        vm.expectPartialRevert(Errors.ConfigValueTooHigh.selector);
        jobCommitment.setApplicantStakeAmount(10_000_001);
    }

    function test_setApplicantStakeAmount_acceptsBounds() public {
        vm.prank(owner);
        jobCommitment.setApplicantStakeAmount(1_000_000);

        assertEq(jobCommitment.applicantStakeAmount(), 1_000_000);

        vm.prank(owner);
        jobCommitment.setApplicantStakeAmount(10_000_000);

        assertEq(jobCommitment.applicantStakeAmount(), 10_000_000);
    }

    // ============ rescueTokens Tests ============

    function test_rescueTokens_stakeToken_rescuesSurplus() public {
        // 1. Apply to a job so applicant stakes are held by JobCommitment
        _publishJob(0);
        _applyToJob(applicant1);

        // totalApplicantStakes == APPLICANT_STAKE (5 USDC)
        uint256 totalStakes = jobCommitment.totalApplicantStakes();
        assertEq(totalStakes, APPLICANT_STAKE);

        // 2. Mint extra USDC directly to JC (unsolicited transfer)
        uint256 surplus = 10_000_000; // 10 USDC
        usdc.mint(address(jobCommitment), surplus);

        // Contract balance should be applicant stakes + surplus
        uint256 balance = usdc.balanceOf(address(jobCommitment));
        assertEq(balance, totalStakes + surplus);

        // 3. Rescue the surplus
        address rescueTo = makeAddr("rescueRecipient");
        vm.prank(owner);
        jobCommitment.rescueTokens(address(usdc), rescueTo, surplus);

        assertEq(usdc.balanceOf(rescueTo), surplus);
        assertEq(usdc.balanceOf(address(jobCommitment)), totalStakes);
    }

    function test_rescueTokens_stakeToken_exceedsSurplus_reverts() public {
        // Apply to a job
        _publishJob(0);
        _applyToJob(applicant1);

        // Mint small surplus
        uint256 surplus = 5_000_000; // 5 USDC
        usdc.mint(address(jobCommitment), surplus);

        // Try to rescue more than surplus
        uint256 tooMuch = surplus + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueExceedsSurplus.selector, tooMuch, surplus));
        jobCommitment.rescueTokens(address(usdc), makeAddr("to"), tooMuch);
    }

    function test_rescueTokens_stakeToken_noSurplus_reverts() public {
        // Apply to a job — balance == applicant stakes exactly
        _publishJob(0);
        _applyToJob(applicant1);

        uint256 totalStakes = jobCommitment.totalApplicantStakes();
        uint256 balance = usdc.balanceOf(address(jobCommitment));
        assertEq(balance, totalStakes, "Balance should equal total stakes");

        // Try to rescue 1 wei — surplus is 0
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Errors.RescueExceedsSurplus.selector, 1, 0));
        jobCommitment.rescueTokens(address(usdc), makeAddr("to"), 1);
    }

    function test_rescueTokens_otherToken_rescuesFullBalance() public {
        // Deploy a second ERC20
        MockToken mockToken = new MockToken();

        // Send some tokens to JC
        uint256 amount = 1_000_000_000; // 1000 tokens
        mockToken.mint(address(jobCommitment), amount);

        assertEq(mockToken.balanceOf(address(jobCommitment)), amount);

        // Rescue full balance — no surplus check for non-stakeToken
        address rescueTo = makeAddr("rescueRecipient");
        vm.prank(owner);
        jobCommitment.rescueTokens(address(mockToken), rescueTo, amount);

        assertEq(mockToken.balanceOf(rescueTo), amount);
        assertEq(mockToken.balanceOf(address(jobCommitment)), 0);
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
        // Not yet applied — but appId was generated, check the next one
        // Actually _generateApplicationId increments nonce, so let's check pre-state
        assertFalse(jobCommitment.isApplicationIdUsed(appId));

        // Apply
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory signature =
            _signApplication(appId, applicant1, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry);
        vm.prank(applicant1);
        jobCommitment.submitApplication(appId, APPLICANT_STAKE_96, DEFAULT_RESPONSE_DEADLINE_DAYS, expiry, signature);

        assertTrue(jobCommitment.isApplicationIdUsed(appId));
    }
}
