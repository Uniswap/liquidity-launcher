// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title TokenDistribution
/// @notice Library for calculating token distribution splits between auction and reserves
/// @dev Handles the splitting of total token supply based on percentage allocations
library TokenDistribution {
    /// @notice Maximum value for token split percentage (100% in basis points)
    /// @dev 1e7 = 10,000,000 basis points = 100%
    uint24 public constant MAX_TOKEN_SPLIT = 1e7;

    /// @notice Calculates the token split based on the split ratio
    /// @param _totalSupply The total token supply
    /// @param _splitMps The percentage to split (in basis points, max 1e7)
    /// @return the split amount of tokens
    function calculateTokenSplit(uint128 _totalSupply, uint24 _splitMps) internal pure returns (uint128) {
        // Safe: totalSupply <= uint128.max and _splitMps <= MAX_TOKEN_SPLIT (1e7)
        // uint256(totalSupply) * _splitMps will never overflow type(uint256).max
        return uint128(uint256(_totalSupply) * _splitMps / MAX_TOKEN_SPLIT);
    }

    /// @notice Calculates the reserve supply (remainder after auction allocation)
    /// @param _totalSupply The total token supply
    /// @param _splitMps The percentage to split (in basis points, max 1e7)
    /// @return the amount of tokens reserved for liquidity
    function calculateReserveSupply(uint128 _totalSupply, uint24 _splitMps) internal pure returns (uint128) {
        return _totalSupply - calculateTokenSplit(_totalSupply, _splitMps);
    }
}
