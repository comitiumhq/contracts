// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Errors} from "../Errors.sol";
import {ExecutorRegistry} from "./ExecutorRegistry.sol";
import {OperatorAuthorizer} from "./OperatorAuthorizer.sol";

/// @title ContractRoles
/// @notice Shared operator and executor role storage with enforced role separation.
abstract contract ContractRoles is OperatorAuthorizer, ExecutorRegistry {
    function _addOperatorChecked(address operator) internal {
        if (_isExecutor(operator)) revert Errors.ProtocolRoleConflict(operator);

        _addOperator(operator);
    }

    function _addExecutorChecked(address executor, address trustedForwarder) internal {
        if (_isOperator(executor) || executor == trustedForwarder) revert Errors.ProtocolRoleConflict(executor);

        _addExecutor(executor);
    }
}
