// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ICommitmentFunds} from "./ICommitmentFunds.sol";

/// @notice Minimal interface used by CommitmentFunds to validate and invoke ResponseCommitment deployments.
interface IResponseCommitmentModule {
    function commitmentVersion() external pure returns (uint32);
    function commitmentFunds() external view returns (ICommitmentFunds);

    function activateCommitment(
        uint256 orgId,
        address creator,
        uint256 stakeAmount,
        uint256 feeAmount,
        bytes calldata activateData
    ) external returns (uint256 commitmentId);
}
