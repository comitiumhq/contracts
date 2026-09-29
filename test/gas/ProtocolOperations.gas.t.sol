// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ResponseCommitmentTestBase, TEST_MAX_ACTIVE_DURATION} from "../shared/TestBase.sol";

/// @notice Gas snapshots for the protocol operations that matter to users and operators.
contract ProtocolOperationsGasTest is ResponseCommitmentTestBase {
    string private constant SNAPSHOT_GROUP = "ProtocolOperations";

    function test_gas_createOrganization() public {
        _createOrgForEmployer(makeAddr("gasOrgCreator"), "gas.com", 2);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "create organization");
    }

    function test_gas_depositCommitmentFunds() public {
        _fundAndDepositWithAuthorization(
            commitmentFunds, address(usdc), employerPrivateKey, DEFAULT_ORG_ID, 100_000_000
        );

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "deposit commitment funds (EIP-3009)");
    }

    function test_gas_activateCommitment() public {
        _activateCommitment(1);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "activate commitment");
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

    function test_gas_settleCommitment() public {
        uint256 commitmentId = _activateCommitment(1);
        bytes32 applicationId = _submitApplication(applicant1);
        _respondToApplication(applicationId);
        _settleCommitment(commitmentId, 1, 1, 1);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "settle commitment (1 responded application)");
    }

    function test_gas_settleExpiredCommitment() public {
        uint256 commitmentId = _activateCommitment(1);
        _submitApplication(applicant1);
        vm.warp(block.timestamp + TEST_MAX_ACTIVE_DURATION + 1);
        _settleExpiredCommitment(commitmentId, 1, 0, 0);

        vm.snapshotGasLastCall(SNAPSHOT_GROUP, "settle expired commitment (1 unanswered application)");
    }
}
