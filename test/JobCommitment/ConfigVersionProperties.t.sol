// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase} from "../shared/TestBase.sol";
import {JobView} from "../../src/interfaces/IJobCommitment.sol";
import {FeeTier, JobConfig} from "../../src/types/ConfigTypes.sol";

contract ConfigVersionPropertiesTest is JobCommitmentTestBase {
    function testFuzz_configVersion_isolatesExistingJobs(uint256 newMinStake) public {
        newMinStake = bound(newMinStake, 50_000_000, 300_000_000);

        // Create job with current config
        uint256 jobId = _publishJob(0);
        JobView memory jobBefore = jobCommitment.job(jobId);

        // Update config
        JobConfig memory newConfig = _defaultJobConfig();
        newConfig.minStake = _toUint96(newMinStake);

        vm.prank(owner);
        jobCommitment.setJobConfig(newConfig, _defaultFeeTiers());

        // Job should still have the same stake and fee as before
        JobView memory jobAfter = jobCommitment.job(jobId);
        assertEq(jobAfter.stake, jobBefore.stake, "Stake must not change after config update");
        assertEq(jobAfter.feeAmount, jobBefore.feeAmount, "Fee must not change after config update");
        assertEq(jobAfter.feeTier, jobBefore.feeTier, "Fee tier must not change after config update");
    }

    function test_configVersion_increments() public {
        uint32 v1 = jobCommitment.currentConfigVersion();

        JobConfig memory config = _defaultJobConfig();
        config.minStake = 200_000_000;

        vm.prank(owner);
        jobCommitment.setJobConfig(config, _defaultFeeTiers());

        uint32 v2 = jobCommitment.currentConfigVersion();
        assertEq(v2, v1 + 1, "Config version must increment by 1");
    }

    function test_configVersion_newJobUsesLatestFee() public {
        // Job 1 with default fees
        uint256 job1 = _publishJob(0);
        JobView memory j1 = jobCommitment.job(job1);

        // Update config with higher fees
        JobConfig memory config = _defaultJobConfig();
        FeeTier[] memory tiers = _defaultFeeTiers();
        tiers[0].feeBps = 300; // was 150
        tiers[1].feeBps = 400; // was 250
        tiers[2].feeBps = 500; // was 350
        vm.prank(owner);
        jobCommitment.setJobConfig(config, tiers);

        // Job 2 with new fees
        _fundOrg(DEFAULT_ORG_ID, employerPrivateKey, 2_000_000_000);
        uint256 job2 = _publishJobWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, "QmNew");
        JobView memory j2 = jobCommitment.job(job2);

        // Job 1 fee should be lower (old config: 150 bps)
        // Job 2 fee should be higher (new config: 300 bps)
        assertLt(j1.feeAmount, j2.feeAmount, "Old job should have lower fee than new job");
    }
}
