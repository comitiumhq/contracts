// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IJobFunds} from "./IJobFunds.sol";

/// @notice Minimal interface used by JobFunds to validate and invoke JobCommitment deployments.
interface IJobCommitmentModule {
    function commitmentVersion() external pure returns (uint32);
    function stakeToken() external view returns (IERC20);
    function jobFunds() external view returns (IJobFunds);

    function createJob(
        uint256 orgId,
        address creator,
        uint256 stakeAmount,
        uint256 feeAmount,
        bytes calldata publishData
    ) external returns (uint256 jobId);
}
