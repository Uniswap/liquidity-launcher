// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ITokenFactory} from "uerc20-factory/src/interfaces/ITokenFactory.sol";
import {IDistributionStrategy} from "./interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "./interfaces/IDistributionContract.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract TokenLauncher {
    /// @notice Represents one distribution instruction: which strategy to use, how many tokens, and any custom data
    struct Distribution {
        address strategy;
        uint256 amount;
        bytes configData;
    }

    /// @notice Error thrown when a token launch doesn't distribute all tokens
    error DistributionIncomplete();

    /// @notice Main entry point for creating and distributing tokens.
    ///      1) Deploys a token via chosen factory.
    ///      2) Distributes tokens via one or more strategies.
    ///  @param factory Address of the factory to use
    ///  @param name Token name
    ///  @param symbol Token symbol
    ///  @param decimals Token decimals
    ///  @param initialSupply Total tokens to be minted (to this contract)
    ///  @param tokenData Extra data needed by the factory
    ///  @param distributions Array of distribution instructions
    function launchToken(
        address factory,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 initialSupply,
        bytes calldata tokenData,
        Distribution[] calldata distributions
    ) external returns (address tokenAddress) {
        // 1) Create token, with this contract as the recipient of the initial supply
        tokenAddress =
            ITokenFactory(factory).createToken(name, symbol, decimals, initialSupply, address(this), tokenData);

        // 2) Distribute tokens
        //    This contract owns the minted tokens, so it must transfer them
        //    according to each Distribution.
        for (uint256 i = 0; i < distributions.length; i++) {
            Distribution calldata dist = distributions[i];

            // Call the strategy: it might do distributions itself or deploy a new instance.
            // If it does distributions itself, distributionContract == dist.strategy
            IDistributionContract distributionContract =
                IDistributionStrategy(dist.strategy).initializeDistribution(tokenAddress, dist.amount, dist.configData);

            // Now transfer the tokens from this contract to the returned address
            IERC20(tokenAddress).transfer(address(distributionContract), dist.amount);

            // Notify the distribution contract that it has received the tokens
            distributionContract.onTokensReceived(tokenAddress, dist.amount);
        }

        if (IERC20(tokenAddress).balanceOf(address(this)) != 0) revert DistributionIncomplete();
    }
}
