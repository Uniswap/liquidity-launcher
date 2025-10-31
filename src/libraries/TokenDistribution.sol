// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title TokenDistribution
/// @notice Library for calculating token distribution splits between auction and reserves
/// @dev Handles the splitting of total token supply based on percentage allocations
library TokenDistribution {
    /// @notice Maximum value for token split percentage (100% in basis points)
    /// @dev 1e7 = 10,000,000 basis points = 100%
    uint24 public constant MAX_TOKEN_SPLIT = 1e7;

    /// @notice Calculates the auction supply based on the split ratio
    /// @param totalSupply The total token supply
    /// @param tokenSplitToAuction The percentage split to auction (in basis points, max 1e7)
    /// @return auctionSupply The amount of tokens allocated to auction
    function calculateAuctionSupply(uint128 totalSupply, uint24 tokenSplitToAuction)
        internal
        pure
        returns (uint128 auctionSupply)
    {
        // Safe: totalSupply <= uint128.max and tokenSplitToAuction <= MAX_TOKEN_SPLIT (1e7)
        // uint256(totalSupply) * tokenSplitToAuction will never overflow type(uint256).max
        auctionSupply = uint128(uint256(totalSupply) * tokenSplitToAuction / MAX_TOKEN_SPLIT);
    }

    /// @notice Calculates the reserve supply (remainder after auction allocation)
    /// @param totalSupply The total token supply
    /// @param tokenSplitToAuction The percentage split to auction (in basis points, max 1e7)
    /// @return reserveSupply The amount of tokens reserved for liquidity
    function calculateReserveSupply(uint128 totalSupply, uint24 tokenSplitToAuction)
        internal
        pure
        returns (uint128 reserveSupply)
    {
        reserveSupply = totalSupply - calculateAuctionSupply(totalSupply, tokenSplitToAuction);
    }
}
