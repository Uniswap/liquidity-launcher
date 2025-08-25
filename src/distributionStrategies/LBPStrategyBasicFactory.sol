// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {LBPStrategyBasic} from "../distributionContracts/LBPStrategyBasic.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";

/// @title LBPStrategyBasicFactory
/// @notice Factory for the LBPStrategyBasic contract
contract LBPStrategyBasicFactory is IDistributionStrategy {
    error InvalidTokenSplit(uint16 tokenSplit);

    /// @notice The token split is measured in bips (10_000 = 100%)
    uint16 public constant TOKEN_SPLIT_DENOMINATOR = 10_000;
    uint16 public constant MAX_TOKEN_SPLIT_TO_AUCTION = 5_000;

    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;

    constructor(IPositionManager _positionManager, IPoolManager _poolManager) {
        positionManager = _positionManager;
        poolManager = _poolManager;
    }

    function getAddressesAndAmounts(address token, uint128 totalSupply, bytes calldata configData, bytes32 salt)
        external
        view
        returns (address[2] memory, uint128[2] memory)
    {
        (
            MigratorParameters memory migratorParams,
            AuctionParameters memory auctionParams,
            address auctionFactory,
            uint16 tokenSplitToAuction
        ) = abi.decode(configData, (MigratorParameters, AuctionParameters, address, uint16));

        if (tokenSplitToAuction > MAX_TOKEN_SPLIT_TO_AUCTION) {
            revert InvalidTokenSplit(tokenSplitToAuction);
        }

        uint128 supplyToAuction = uint128(uint256(totalSupply) * uint256(tokenSplitToAuction) / TOKEN_SPLIT_DENOMINATOR);
        uint128 supplyToLBP = totalSupply - supplyToAuction;

        // create LBP
        bytes32 _salt = keccak256(abi.encode(msg.sender, salt));
        address lbp = getLBPAddress(token, supplyToLBP, abi.encode(migratorParams), _salt);
        address auction =
            getAuctionAddress(auctionFactory, token, supplyToAuction, abi.encode(auctionParams, lbp), _salt);

        return ([lbp, auction], [supplyToLBP, supplyToAuction]);
    }

    /// @inheritdoc IDistributionStrategy
    function initializeDistribution(address token, uint128 totalSupply, bytes calldata configData, bytes32 salt)
        external
    {
        (
            MigratorParameters memory migratorParams,
            AuctionParameters memory auctionParams,
            address auctionFactory,
            uint16 tokenSplitToAuction
        ) = abi.decode(configData, (MigratorParameters, AuctionParameters, address, uint16));

        if (tokenSplitToAuction > MAX_TOKEN_SPLIT_TO_AUCTION) {
            revert InvalidTokenSplit(tokenSplitToAuction);
        }

        uint128 supplyToAuction = uint128(uint256(totalSupply) * uint256(tokenSplitToAuction) / TOKEN_SPLIT_DENOMINATOR);
        uint128 supplyToLBP = totalSupply - supplyToAuction;

        bytes32 _salt = keccak256(abi.encode(msg.sender, salt));
        address lbp =
            address(new LBPStrategyBasic{salt: _salt}(token, supplyToLBP, migratorParams, positionManager, poolManager));

        IDistributionStrategy(auctionFactory).initializeDistribution(
            token, supplyToAuction, abi.encode(auctionParams), _salt
        );

        emit DistributionInitialized(address(lbp), token, totalSupply);
    }

    function getLBPAddress(address token, uint256 totalSupply, bytes memory configData, bytes32 salt)
        public
        view
        returns (address)
    {
        (MigratorParameters memory migratorParams) = abi.decode(configData, (MigratorParameters));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(LBPStrategyBasic).creationCode,
                abi.encode(token, totalSupply, migratorParams, positionManager, poolManager)
            )
        );
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }

    function getAuctionAddress(
        address auctionFactory,
        address token,
        uint128 totalSupply,
        bytes memory configData,
        bytes32 salt
    ) public view returns (address) {
        (address[2] memory addresses, uint128[2] memory amounts) =
            IDistributionStrategy(auctionFactory).getAddressesAndAmounts(token, totalSupply, configData, salt);
        return addresses[0];
    }
}
