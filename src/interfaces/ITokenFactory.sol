// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ITokenFactory
 * @dev Generic interface for a token factory.
 */
interface ITokenFactory {
    /**
     * @notice Creates a new token contract
     * @dev The token must be minted so that `totalSupply` is owned by the caller
     * @param name        The ERC20-style name of the token.
     * @param symbol      The ERC20-style symbol of the token.
     * @param decimals    The number of decimal places for the token.
     * @param totalSupply The total supply to mint upon creation.
     * @param data        Additional factory-specific data required for token creation.
     * @return tokenAddress The address of the newly created token.
     */
    function createToken(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 totalSupply,
        bytes calldata data
    ) external returns (address tokenAddress);
}
