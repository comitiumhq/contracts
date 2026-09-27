// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase} from "../shared/TestBase.sol";
import {CommitmentView} from "../../src/interfaces/IResponseCommitment.sol";
import {FeeTier, CommitmentConfig} from "../../src/types/ConfigTypes.sol";

contract ConfigVersionPropertiesTest is ResponseCommitmentTestBase {
    function testFuzz_configVersion_isolatesExistingCommitments(uint256 newMinStake) public {
        newMinStake = bound(newMinStake, 50_000_000, 300_000_000);

        uint256 commitmentId = _activateCommitment(0);
        CommitmentView memory commitmentBefore = responseCommitment.commitment(commitmentId);

        CommitmentConfig memory newConfig = _defaultCommitmentConfig();
        newConfig.minStake = _toUint96(newMinStake);

        vm.prank(owner);
        responseCommitment.setCommitmentConfig(newConfig, _defaultFeeTiers());

        CommitmentView memory commitmentAfter = responseCommitment.commitment(commitmentId);
        assertEq(commitmentAfter.stake, commitmentBefore.stake, "Stake must not change after config update");
        assertEq(commitmentAfter.feeAmount, commitmentBefore.feeAmount, "Fee must not change after config update");
        assertEq(commitmentAfter.feeTier, commitmentBefore.feeTier, "Fee tier must not change after config update");
    }

    function test_configVersion_increments() public {
        uint32 v1 = responseCommitment.currentConfigVersion();

        CommitmentConfig memory config = _defaultCommitmentConfig();
        config.minStake = 200_000_000;

        vm.prank(owner);
        responseCommitment.setCommitmentConfig(config, _defaultFeeTiers());

        uint32 v2 = responseCommitment.currentConfigVersion();
        assertEq(v2, v1 + 1, "Config version must increment by 1");
    }

    function test_configVersion_newCommitmentUsesLatestFee() public {
        uint256 commitment1 = _activateCommitment(0);
        CommitmentView memory j1 = responseCommitment.commitment(commitment1);

        CommitmentConfig memory config = _defaultCommitmentConfig();
        FeeTier[] memory tiers = _defaultFeeTiers();
        tiers[0].feeBps = 300; // was 150
        tiers[1].feeBps = 400; // was 250
        tiers[2].feeBps = 500; // was 350
        vm.prank(owner);
        responseCommitment.setCommitmentConfig(config, tiers);

        _fundOrg(DEFAULT_ORG_ID, employerPrivateKey, 2_000_000_000);
        uint256 commitment2 = _activateCommitmentWithParams(DEFAULT_ORG_ID, EMPLOYER_STAKE, 0, keccak256("QmNew"));
        CommitmentView memory j2 = responseCommitment.commitment(commitment2);

        assertLt(j1.feeAmount, j2.feeAmount, "Old commitment should have lower fee than new commitment");
    }
}
