// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {Errors} from "../Errors.sol";

/// @title OwnerControls
/// @notice Shared owner-level controls for immutable Comitium protocol contracts.
abstract contract OwnerControls is Ownable2Step, Pausable, ReentrancyGuardTransient, ERC2771Context {
    using SafeERC20 for IERC20;

    constructor(address owner_, address forwarder_) Ownable(owner_) ERC2771Context(forwarder_) {}

    /// @dev Recover the original EOA for functions that explicitly support ERC-2771 user authority.
    function _actor() internal view virtual returns (address) {
        return ERC2771Context._msgSender();
    }

    function _actorCalldata() internal view returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @notice Disable ownership renunciation to preserve administrative recovery.
    function renounceOwnership() public view override onlyOwner {
        revert Errors.RenounceDisabled();
    }

    /// @notice Pause new state-changing protocol entry points guarded by `whenNotPaused`.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume paused protocol entry points.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Rescue tokens accidentally sent to this contract.
    /// @param token Token address to rescue.
    /// @param to Recipient address.
    /// @param amount Amount to rescue.
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert Errors.ZeroAddress();

        _validateTokenRescue(token, amount);
        IERC20(token).safeTransfer(to, amount);
        _emitTokensRescued(token, to, amount);
    }

    /// @dev Hook for contracts that account balances and must protect non-surplus funds.
    function _validateTokenRescue(address token, uint256 amount) internal view virtual {}

    /// @dev Emits the contract-specific rescue event declared by its public interface.
    function _emitTokensRescued(address token, address to, uint256 amount) internal virtual;

    /// @dev Owner/admin controls intentionally keep raw callers; relayed user authority must call `_actor()`.
    function _msgSender() internal view override(Context, ERC2771Context) returns (address) {
        return Context._msgSender();
    }

    /// @dev Resolves the Context/ERC2771Context inheritance; owner/admin paths keep raw calldata.
    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return Context._msgData();
    }

    /// @dev Resolves the Context/ERC2771Context inheritance for ERC-2771 calldata suffix handling.
    function _contextSuffixLength() internal view override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}
