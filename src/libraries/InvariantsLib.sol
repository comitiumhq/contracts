// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title InvariantsLib
/// @notice Shared invariant assertions for token-backed accounting.
library InvariantsLib {
    /// @notice Assert that a token balance covers tracked accounting.
    /// @dev Uses assert because a violation is a contract accounting bug, not user input.
    function assertBalanceGte(IERC20 token, address account, uint256 tracked) internal view {
        assert(token.balanceOf(account) >= tracked);
    }
}
