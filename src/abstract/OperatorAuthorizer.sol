// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {NoncesKeyed} from "@openzeppelin/contracts/utils/NoncesKeyed.sol";

import {Errors} from "../Errors.sol";

/// @title OperatorAuthorizer
/// @notice Reusable EIP-712 operator authorization with independent keyed nonce streams.
/// @dev Contract-specific domains, message schemas, and nonce scopes are supplied by each consumer.
abstract contract OperatorAuthorizer is EIP712, NoncesKeyed {
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _operators;

    event OperatorUpdated(address indexed operator, bool active, address indexed actor);

    constructor(string memory domainName, string memory domainVersion, address initialOperator)
        EIP712(domainName, domainVersion)
    {
        _addOperator(initialOperator);
    }

    function _isOperator(address operator) internal view returns (bool) {
        return _operators.contains(operator);
    }

    function _addOperator(address operator) internal {
        if (operator == address(0)) revert Errors.ZeroAddress();
        if (!_operators.add(operator)) revert Errors.OperatorAlreadyRegistered(operator);

        emit OperatorUpdated(operator, true, msg.sender);
    }

    function _removeOperator(address operator) internal {
        if (!_operators.contains(operator)) revert Errors.NotOperator();
        if (_operators.length() <= 1) revert Errors.CannotRemoveLastOperator();

        bool removed = _operators.remove(operator);
        assert(removed);

        emit OperatorUpdated(operator, false, msg.sender);
    }

    function _operatorsList() internal view returns (address[] memory operators_) {
        return _operators.values();
    }

    /// @notice Verify an operator authorization whose replay protection is enforced by domain state.
    /// @dev The supplied struct hash must bind the exact `expiry` value passed to this function.
    function _verifyOperatorAuthorization(bytes32 structHash, uint256 expiry, bytes memory signature)
        internal
        view
        returns (address signer)
    {
        if (block.timestamp > expiry) revert Errors.SignatureExpired();

        signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);

        if (!_isOperator(signer)) revert Errors.InvalidSignature();
    }

    /// @notice Verify an operator authorization and consume its contract-specific keyed nonce.
    /// @dev The supplied struct hash must bind the exact `keyNonce` and `expiry` values passed to this function.
    function _consumeOperatorAuthorization(
        bytes32 structHash,
        uint16 expectedScope,
        uint256 keyNonce,
        uint256 expiry,
        bytes memory signature
    ) internal {
        address signer = _verifyOperatorAuthorization(structHash, expiry, signature);
        uint16 providedScope = (keyNonce >> 240).toUint16();

        if (providedScope != expectedScope) revert Errors.InvalidNonceScope(providedScope, expectedScope);

        _useCheckedNonce(signer, keyNonce);
    }

    function _operatorDomainSeparator() internal view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
