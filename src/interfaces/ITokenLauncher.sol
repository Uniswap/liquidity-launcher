// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Distribution} from "../types/Distribution.sol";

/// @title ITokenLauncher
/// @notice Interface for the TokenLauncher contract
interface ITokenLauncher {
    /// @notice Emitted when a token is created
    /// @param tokenAddress The address of the token that was created
    event TokenCreated(address indexed tokenAddress);

    /// @notice Emitted when a token is distributed
    /// @param tokenAddress The address of the token that was distributed
    /// @param addresses The addresses of the contracts that will handle or manage the distribution
    /// @param amounts The amounts of tokens that were distributed to each address
    event TokenDistributed(address indexed tokenAddress, address[2] indexed addresses, uint128[2] amounts);

    /// @notice Creates and distributes tokens.
    ///      1) Deploys a token via chosen factory.
    ///      2) Distributes tokens via one or more strategies.
    ///  @param factory Address of the factory to use
    ///  @param name Token name
    ///  @param symbol Token symbol
    ///  @param decimals Token decimals
    ///  @param initialSupply Total tokens to be minted (to this contract)
    ///  @param tokenData Extra data needed by the factory
    ///  @return tokenAddress The address of the token that was created
    function createToken(
        address factory,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint128 initialSupply,
        address recipient,
        bytes calldata tokenData
    ) external returns (address tokenAddress);

    /// @notice Transfer tokens already created to this contract and distribute them via one or more strategies
    /// @param tokenAddress The address of the token to distribute
    /// @param distribution Distribution instructions
    /// @param payerIsUser Whether the payer is the user
    /// @param salt The salt to pass into the distribution strategy contract if needed
    /// @return addresses The addresses of the contracts that will handle or manage the distribution.
    function distributeToken(address tokenAddress, Distribution memory distribution, bool payerIsUser, bytes32 salt)
        external
        returns (address[2] memory, uint128[2] memory);

    /// @notice Calculates the graffiti that will be used for a token creation
    /// @param originalCreator The address that will be set as the original creator
    /// @return graffiti The graffiti bytes32 that will be used
    function getGraffiti(address originalCreator) external view returns (bytes32 graffiti);
}
