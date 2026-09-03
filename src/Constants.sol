// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

// ============ Structural Constants ============

// Denominator for basis-point ratios (1 bp = 1/10000).
uint256 constant BASIS_POINTS = 10_000;

// Address used as an unrecoverable sink for slashed organization stake.
address constant SLASH_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
