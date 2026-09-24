// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {JobCommitmentTestBase, TEST_MAX_PUBLISHED_DURATION} from "../shared/TestBase.sol";

/// @notice Gas snapshots for the protocol operations that matter to users and operators.
contract ProtocolOperationsGasTest is JobCommitmentTestBase {
    string private constant SNAPSHOT_GROUP = "ProtocolOperations";

    function test_gas_createOrganization() public {
        _createOrgForEmployer(makeAddr("gasOrgCreator"), "gas.com", 2);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "create organization");
    }

    function test_gas_depositJobFunds() public {
        _fundAndDepositWithAuthorization(jobFunds, address(usdc), employerPrivateKey, DEFAULT_ORG_ID, 100_000_000);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "deposit job funds (EIP-3009)");
    }

    function test_gas_publishJob() public {
        _publishJob(1);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "publish job");
    }

    function test_gas_submitApplication() public {
        _submitApplication(applicant1);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "submit application");
    }

    function test_gas_recordApplicationResponse() public {
        bytes32 applicationId = _submitApplication(applicant1);
        _respondToApplication(applicationId);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "record application response");
    }

    function test_gas_closeJob() public {
        uint256 jobId = _publishJob(1);
        bytes32 applicationId = _submitApplication(applicant1);
        _respondToApplication(applicationId);
        _closeJob(jobId, 1, 1, 1);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "close job (1 responded application)");
    }

    function test_gas_settleExpiredJob() public {
        uint256 jobId = _publishJob(1);
        _submitApplication(applicant1);
        vm.warp(block.timestamp + TEST_MAX_PUBLISHED_DURATION + 1);
        _settleExpiredJob(jobId, 1, 0, 0);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "settle expired job (1 unanswered application)");
    }
}
