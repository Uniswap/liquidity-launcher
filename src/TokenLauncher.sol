// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITokenFactory} from "./interfaces/ITokenFactory.sol";
import {IDistributionStrategy} from "./interfaces/IDistributionStrategy.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract TokenLauncher is Ownable {
    /// @dev Token factories: (factoryId => factoryAddress).
    mapping(bytes32 => address) public tokenFactories;

    /// @dev Distribution strategies: (strategyId => strategyAddress).
    mapping(bytes32 => address) public distributionStrategies;

    /// @dev Represents one distribution instruction:
    ///      which strategy to use, how many tokens, and any custom data.
    struct Distribution {
        bytes32 strategy;
        uint256 amount;
        bytes configData;
    }

    /// @dev Error thrown when an invalid token factory is provided
    error InvalidFactory();

    /// @dev Error thrown when an invalid distribution strategy is provided
    error InvalidStrategy();

    /// @dev Error thrown when a token launch doesn't distribute all tokens
    error DistributionIncomplete();

    constructor() Ownable(msg.sender) {}

    /// @dev Adds, updates, or removes a factory
    function updateFactory(bytes32 id, address factory) external onlyOwner {
        tokenFactories[id] = factory;
    }

    /// @dev Adds, updates, or removes a strategy
    function updateStrategy(bytes32 id, address strategy) external onlyOwner {
        distributionStrategies[id] = strategy;
    }

    /**
     * @dev Main entry point for creating and distributing tokens.
     *      1) Deploys a token via chosen factory.
     *      2) Distributes tokens via one or more strategies.
     *
     * @param factoryId   ID of the token factory to use
     * @param name        Token name
     * @param symbol      Token symbol
     * @param decimals    Token decimals
     * @param initialSupply Total tokens to be minted (to this contract)
     * @param tokenData   Extra data needed by the factory
     * @param distributions Array of distribution instructions
     */
    function launchToken(
        bytes32 factoryId,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 initialSupply,
        bytes calldata tokenData,
        Distribution[] calldata distributions
    ) external returns (address tokenAddress) {
        address factory = tokenFactories[factoryId];
        if (factory == address(0)) revert InvalidFactory();

        // 1) Create token, with this contract as the recipient of the initial supply
        tokenAddress =
            ITokenFactory(factory).createToken(name, symbol, decimals, initialSupply, address(this), tokenData);

        // 2) Distribute tokens
        //    This contract owns the minted tokens, so it must transfer them
        //    according to each Distribution.
        for (uint256 i = 0; i < distributions.length; i++) {
            Distribution calldata dist = distributions[i];
            address strategyAddr = distributionStrategies[dist.strategy];
            if (strategyAddr == address(0)) revert InvalidStrategy();

            // Call the strategy: it might do distribution directly or deploy a new instance.
            address distributionContract =
                IDistributionStrategy(strategyAddr).initializeDistribution(tokenAddress, dist.amount, dist.configData);

            // Now transfer the tokens from this contract to the returned address
            IERC20(tokenAddress).transfer(distributionContract, dist.amount);
        }

        if (IERC20(tokenAddress).balanceOf(address(this)) != 0) revert DistributionIncomplete();
    }
}
