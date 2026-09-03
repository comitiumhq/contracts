// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {Errors} from "../Errors.sol";

/// @title ExecutorRegistry
/// @notice Registry of accounts authorized to execute restricted direct calls.
abstract contract ExecutorRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _executors;

    event ExecutorUpdated(address indexed executor, bool active, address indexed actor);

    modifier onlyExecutor() {
        if (!_executors.contains(msg.sender)) revert Errors.NotExecutor();
        _;
    }

    function _isExecutor(address executor) internal view returns (bool) {
        return _executors.contains(executor);
    }

    function _addExecutor(address executor) internal {
        if (executor == address(0)) revert Errors.ZeroAddress();
        if (!_executors.add(executor)) revert Errors.ExecutorAlreadyRegistered(executor);

        emit ExecutorUpdated(executor, true, msg.sender);
    }

    function _removeExecutor(address executor) internal {
        if (!_executors.contains(executor)) revert Errors.NotExecutor();
        if (_executors.length() <= 1) revert Errors.CannotRemoveLastExecutor();

        bool removed = _executors.remove(executor);
        assert(removed);

        emit ExecutorUpdated(executor, false, msg.sender);
    }

    function _executorsList() internal view returns (address[] memory executors_) {
        return _executors.values();
    }
}
