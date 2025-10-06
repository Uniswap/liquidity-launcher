// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LBPStrategyBasicImpl} from "./LBPStrategyBasicImpl.sol";
import {IVirtualERC20} from "../interfaces/external/VirtualERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Math} from "@openzeppelin-latest/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TokenPricing} from "../libraries/TokenPricing.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {Auction} from "twap-auction/src/Auction.sol";
import {GovernanceHook} from "../utils/GovernanceHook.sol";
import {MigrationData} from "../types/MigrationData.sol";

/// @title VirtualLBPStrategyBasic
/// @notice Strategy for distributing virtual tokens to a v4 pool
/// Virtual tokens are ERC20 tokens that wrap an underlying token. 

// TODO(md): make sure that the governance hook is inherited from, NOT overidden by hook basic
contract VirtualLBPStrategyBasic is LBPStrategyBasicImpl, GovernanceHook {
    using TokenPricing for *;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory migratorParams,
        bytes memory auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        address _governance
    ) 
    // Underlying strategy
    LBPStrategyBasicImpl(_token, _totalSupply, migratorParams, auctionParams, _positionManager) 
    // Governance hook implementation
    GovernanceHook(_poolManager, _governance) 
    {}

    function _initializePool(MigrationData memory data) internal override(LBPStrategyBasicImpl) returns (PoolKey memory key) {
        address underlyingToken = IVirtualERC20(token).UNDERLYING_TOKEN_ADDRESS();

        key = PoolKey({
            currency0: Currency.wrap(currency < underlyingToken ? currency : underlyingToken),
            currency1: Currency.wrap(currency < underlyingToken ? underlyingToken : currency),
            fee: poolLPFee,
            tickSpacing: poolTickSpacing,
            hooks: IHooks(address(this))
        });

        poolManager.initialize(key, data.sqrtPriceX96);

        return key;
    }

    function _prepareMigrationData() internal view override(LBPStrategyBasicImpl) returns (MigrationData memory data) {
        uint128 currencyRaised = uint128(auction.currencyRaised()); // already validated to be less than or equal to type(uint128).max
        address underlyingToken = IVirtualERC20(token).UNDERLYING_TOKEN_ADDRESS();

        uint256 priceX192 = auction.clearingPrice().convertToPriceX192(currency < underlyingToken);
        data.sqrtPriceX96 = priceX192.convertToSqrtPriceX96();

        (data.initialTokenAmount, data.leftoverCurrency, data.initialCurrencyAmount) =
            priceX192.calculateAmounts(currencyRaised, currency < underlyingToken, reserveSupply);

        data.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            data.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing),
            currency < underlyingToken ? data.initialCurrencyAmount : data.initialTokenAmount,
            currency < underlyingToken ? data.initialTokenAmount : data.initialCurrencyAmount
        );

        _validateLiquidity(data.liquidity);

        // Determine if we should create a one-sided position in tokens if createOneSidedTokenPosition is set OR
        // if we should create a one-sided position in currency if createOneSidedCurrencyPosition is set and there is leftover currency
        data.shouldCreateOneSided = createOneSidedTokenPosition && reserveSupply > data.initialTokenAmount
            || createOneSidedCurrencyPosition && data.leftoverCurrency > 0;

        return data;
    }
}