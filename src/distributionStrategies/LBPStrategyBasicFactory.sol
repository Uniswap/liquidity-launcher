// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {LBPStrategyBasic} from "../distributionContracts/LBPStrategyBasic.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";

/// @title LBPStrategyBasicFactory
/// @notice Factory for the LBPStrategyBasic contract
contract LBPStrategyBasicFactory is IDistributionStrategy {
    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;

    constructor(IPositionManager _positionManager, IPoolManager _poolManager) {
        positionManager = _positionManager;
        poolManager = _poolManager;
    }

    /// @inheritdoc IDistributionStrategy
    function initializeDistribution(address token, uint128 totalSupply, bytes calldata configData, bytes32 salt)
        external
        returns (IDistributionContract lbp)
    {
        (MigratorParameters memory migratorParams, AuctionParameters memory auctionParams) =
            abi.decode(configData, (MigratorParameters, AuctionParameters));

        bytes32 _salt = keccak256(abi.encode(msg.sender, salt));
        lbp = IDistributionContract(
            address(
                new LBPStrategyBasic{salt: _salt}(
                    token, totalSupply, migratorParams, auctionParams, positionManager, poolManager
                )
            )
        );

        emit DistributionInitialized(address(lbp), token, totalSupply);
    }

    function getLBPAddress(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
        view
        returns (address)
    {
        (MigratorParameters memory migratorParams, bytes memory auctionParams) =
            abi.decode(configData, (MigratorParameters, bytes));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(LBPStrategyBasic).creationCode,
                abi.encode(token, totalSupply, migratorParams, auctionParams, positionManager, poolManager)
            )
        );
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }
}
