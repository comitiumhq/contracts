// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IJobFunds} from "./IJobFunds.sol";

/// @notice Minimal interface used by JobFunds to validate and invoke JobCommitment deployments.
interface IJobCommitmentModule {
    function commitmentVersion() external pure returns (uint32);
    function jobFunds() external view returns (IJobFunds);

    function createJob(
        uint256 orgId,
        address creator,
        uint256 stakeAmount,
        uint256 feeAmount,
        bytes calldata publishData
    ) external returns (uint256 jobId);
}
