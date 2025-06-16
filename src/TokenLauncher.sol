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

    /// @notice Error thrown when distribution amounts don't match expected total
    error DistributionAmountMismatch();

    /// @notice Creates and distributes tokens.
    ///      1) Deploys a token via chosen factory.
    ///      2) Distributes tokens via one or more strategies.
    ///  @param factory Address of the factory to use
    ///  @param name Token name
    ///  @param symbol Token symbol
    ///  @param decimals Token decimals
    ///  @param initialSupply Total tokens to be minted (to this contract)
    ///  @param tokenData Extra data needed by the factory
    ///  @param distributions Array of distribution instructions
    ///  @return tokenAddress The address of the token that was created
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
            ITokenFactory(factory).createToken(name, symbol, decimals, initialSupply, address(this), tokenData, "");

        // 2) Distribute tokens
        _distribute(tokenAddress, initialSupply, distributions);
    }

    /// @notice Transfer tokens already created to this contract and distribute them via one or more strategies
    /// @param token The address of the token to distribute
    /// @param amount The amount of tokens to distribute
    /// @param distributions Array of distribution instructions
    function transferAndDistribute(address token, uint256 amount, Distribution[] calldata distributions) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        _distribute(token, amount, distributions);
    }

    /// @notice Distribute tokens via one or more strategies
    /// @param token The address of the token to distribute
    /// @param expectedAmount The total amount that should be distributed
    /// @param distributions Array of distribution instructions
    function _distribute(address token, uint256 expectedAmount, Distribution[] calldata distributions) internal {
        uint256 totalDistribution = 0;

        // Execute distributions while accumulating total
        for (uint256 i = 0; i < distributions.length; i++) {
            Distribution calldata dist = distributions[i];
            totalDistribution += dist.amount;

            // Call the strategy: it might do distributions itself or deploy a new instance.
            // If it does distributions itself, distributionContract == dist.strategy
            IDistributionContract distributionContract =
                IDistributionStrategy(dist.strategy).initializeDistribution(token, dist.amount, dist.configData);

            // Now transfer the tokens from this contract to the returned address
            IERC20(token).transfer(address(distributionContract), dist.amount);

            // Notify the distribution contract that it has received the tokens
            distributionContract.onTokensReceived(token, dist.amount);
        }

        // Validate that distribution amounts sum to expected total
        if (totalDistribution != expectedAmount) revert DistributionAmountMismatch();
    }
}
