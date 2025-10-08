// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyBasic} from "./LBPStrategyBasic.sol";
import {IVirtualERC20} from "../interfaces/external/VirtualERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Math} from "@openzeppelin-latest/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BasePositionParams, FullRangeParams, OneSidedParams} from "../types/PositionTypes.sol";
import {ParamsBuilder} from "../libraries/ParamsBuilder.sol";
import {TokenPricing} from "../libraries/TokenPricing.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {Auction} from "twap-auction/src/Auction.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {MigrationData} from "../types/MigrationData.sol";

/// @title VirtualLBPStrategyBasic
/// @notice Strategy for distributing virtual tokens to a v4 pool
/// Virtual tokens are ERC20 tokens that wrap an underlying token. 

// TODO(md): make sure that the governance hook is inherited from, NOT overidden by hook basic
contract VirtualLBPStrategyBasic is LBPStrategyBasic {
    using TokenPricing for *;

    event MigrationApproved();
    event GovernanceSet(address govnerance);

    error MigrationNotApproved();
    error NotGovernance();

    /// @notice The address of Aztec Governance
    address immutable GOVERNANCE;

    /// @notice Whether migration is approved by Governance
    bool public isMigrationApproved = false;

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
    LBPStrategyBasic(_token, _totalSupply, migratorParams, auctionParams, _positionManager, _poolManager) 
    {
      GOVERNANCE = _governance;
      emit GovernanceSet(_governance);
    }

    function approveMigration() external {
      if (msg.sender != GOVERNANCE) revert NotGovernance();
      isMigrationApproved = true;
      emit MigrationApproved();
    }

    function _initializePool(MigrationData memory data) internal override(LBPStrategyBasic) returns (PoolKey memory key) {
        if (!isMigrationApproved) revert MigrationNotApproved();
        
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

    function _prepareMigrationData() internal view override(LBPStrategyBasic) returns (MigrationData memory data) {
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
    
    function _createPositionPlan(MigrationData memory data) internal override(LBPStrategyBasic) view returns (bytes memory plan) {
        bytes memory actions;
        bytes[] memory params;
        
        address underlyingToken = IVirtualERC20(token).UNDERLYING_TOKEN_ADDRESS();

        // Create base parameters
        BasePositionParams memory baseParams = BasePositionParams({
            currency: currency,
            token: underlyingToken,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            initialSqrtPriceX96: data.sqrtPriceX96,
            liquidity: data.liquidity,
            positionRecipient: positionRecipient,
            hooks: IHooks(address(this))
        });

        if (data.shouldCreateOneSided) {
            (actions, params) = _createFullRangePositionPlan(
                baseParams,
                data.initialTokenAmount,
                data.initialCurrencyAmount,
                ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE
            );
            (actions, params) =
                _createOneSidedPositionPlan(baseParams, actions, params, data.initialTokenAmount, data.leftoverCurrency);
            // shouldCreatedOneSided could be true, but if the one sided position is not valid, only a full range position will be created and there will be no one sided params
            data.hasOneSidedParams = params.length == ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE;
        } else {
            (actions, params) = _createFullRangePositionPlan(
                baseParams, data.initialTokenAmount, data.initialCurrencyAmount, ParamsBuilder.FULL_RANGE_SIZE
            );
        }

        return abi.encode(actions, params);
    }
}
