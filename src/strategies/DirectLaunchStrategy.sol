// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionPlanner} from "../libraries/PositionPlanner.sol";
import {MigratorParams} from "../libraries/MigratorParams.sol";
import {DirectLaunchParams, DirectLaunchParameters} from "../libraries/DirectLaunchParams.sol";
import {IDirectLaunchStrategy} from "../interfaces/IDirectLaunchStrategy.sol";
import {ILaunchHook, LaunchConfig} from "../interfaces/ILaunchHook.sol";
import {Plan, Position, PositionDefinition, CurrencyAmounts} from "../types/PositionPlannerTypes.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/// @title DirectLaunchStrategy
/// @notice Strategy that launches a token directly into a freshly initialized v4 pool as single-sided liquidity
/// @dev The entire distribution is placed as token-only positions at or above the initial price; buyers swap
///      the pool currency in to move the price through the tiers. Hooks supporting ILaunchHook additionally
///      receive a launch configuration (swap gate + windowed fee module) before the pool is initialized.
///      Supply that cannot be placed (per-tick liquidity cap or rounding) is swept to the configured recipient.
/// @custom:security-contact security@uniswap.org
contract DirectLaunchStrategy is IDirectLaunchStrategy, ReentrancyGuardTransient {
    using DirectLaunchParams for DirectLaunchParameters;
    using MigratorParams for address;

    /// @notice The v4 pool manager
    IPoolManager public immutable poolManager;
    /// @notice The v4 position manager
    IPositionManager public immutable positionManager;

    constructor(IPositionManager _positionManager, IPoolManager _poolManager) {
        positionManager = _positionManager;
        poolManager = _poolManager;
    }

    /// @notice Initialize a direct launch distribution.
    /// @dev Validates the params, registers the launch configuration on ILaunchHook-conforming hooks, pulls
    ///      `totalSupply` tokens from the caller, initializes the pool at the configured price, and mints the
    ///      single-sided position plan. The caller (typically the launcher) must have approved this strategy
    ///      for at least `totalSupply` of `token` before calling.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        nonReentrant
    {
        // The pool currency can be native ETH, but the launched token must be ERC20.
        if (token == address(0)) revert ZeroAddressToken();
        // v4's PoolManager._accountDelta uses int128 for deltas; the entire supply is placed as position amounts.
        if (totalSupply == 0 || totalSupply > uint128(type(int128).max)) {
            revert InvalidAmount(totalSupply, uint128(type(int128).max));
        }

        DirectLaunchParameters memory params = abi.decode(configData, (DirectLaunchParameters));

        Currency tokenCurrency = Currency.wrap(token);
        bool tokenIsCurrency0 = tokenCurrency < Currency.wrap(params.currency);
        params.validate(token, tokenIsCurrency0);

        PoolKey memory key = PoolKey({
            currency0: tokenIsCurrency0 ? tokenCurrency : Currency.wrap(params.currency),
            currency1: tokenIsCurrency0 ? Currency.wrap(params.currency) : tokenCurrency,
            fee: params.poolParameters.fee,
            tickSpacing: params.poolParameters.tickSpacing,
            hooks: IHooks(params.poolParameters.hook)
        });
        PoolId poolId = key.toId();
        params.poolParameters.hook.validateHook(params.poolParameters.fee, poolId, poolManager);
        _registerLaunchConfig(params.poolParameters.hook, poolId, params.launchConfig, tokenIsCurrency0);

        // Fee-on-transfer tokens are unsupported because the position plan requires the supply to arrive exactly.
        uint256 balanceBefore = tokenCurrency.balanceOfSelf();
        SafeERC20.safeTransferFrom(IERC20(token), msg.sender, address(this), totalSupply);
        {
            uint256 received = tokenCurrency.balanceOfSelf() - balanceBefore;
            if (received != totalSupply) revert TokenAmountMismatch(received, totalSupply);
        }

        poolManager.initialize(key, params.initialSqrtPriceX96);

        bytes memory plan = _mintPositions(key, tokenCurrency, tokenIsCurrency0, uint128(totalSupply), params);

        // Sweep rounding dust returned by the plan's TAKE_PAIR plus any supply the plan could not place.
        _sweepToken(tokenCurrency, params.recipient, tokenCurrency.balanceOfSelf() - balanceBefore);

        emit TokenLaunched(poolId, token, key, params.initialSqrtPriceX96, plan);
    }

    /// @notice Builds the position plan, funds the PositionManager, and executes the mint
    /// @return plan The encoded PositionManager plan that was executed
    function _mintPositions(
        PoolKey memory key,
        Currency tokenCurrency,
        bool tokenIsCurrency0,
        uint128 tokenAmount,
        DirectLaunchParameters memory params
    ) private returns (bytes memory plan) {
        uint128 tokenTransferAmount;
        (plan, tokenTransferAmount) = _createPositionPlan(key, tokenIsCurrency0, tokenAmount, params);
        tokenCurrency.transfer(address(positionManager), tokenTransferAmount);
        positionManager.modifyLiquidities(plan, block.timestamp);
    }

    /// @notice Builds the single-sided position plan to be executed against the PositionManager
    /// @dev The token budget covers the entire supply and the currency budget is zero, so every resolved
    ///      position quotes liquidity purely from the token side (enforced by validateSingleSided).
    /// @param key the pool key for the launch
    /// @param tokenIsCurrency0 Whether the token is currency0 of the pool
    /// @param tokenAmount The token budget for LP positions
    /// @param params The launch parameters
    /// @return plan The encoded PositionManager plan
    /// @return tokenTransferAmount The token amount consumed by the plan
    function _createPositionPlan(
        PoolKey memory key,
        bool tokenIsCurrency0,
        uint128 tokenAmount,
        DirectLaunchParameters memory params
    ) internal pure returns (bytes memory plan, uint128 tokenTransferAmount) {
        (Position[] memory positions, CurrencyAmounts memory remainingAmounts) = PositionPlanner.resolve(
            abi.decode(params.positionDefinitions, (PositionDefinition[])),
            params.initialSqrtPriceX96,
            params.poolParameters.tickSpacing,
            CurrencyAmounts({amount0: tokenIsCurrency0 ? tokenAmount : 0, amount1: tokenIsCurrency0 ? 0 : tokenAmount}),
            params.positionRecipient
        );
        if (positions.length == 0) revert NoPositionsCreated();

        tokenTransferAmount = tokenIsCurrency0
            ? tokenAmount - SafeCastLib.toUint128(remainingAmounts.amount0)
            : tokenAmount - SafeCastLib.toUint128(remainingAmounts.amount1);

        Plan memory encodedPlan = PositionPlanner.toPlan(positions, key, ActionConstants.MSG_SENDER);
        plan = abi.encode(encodedPlan.actions, encodedPlan.params);
    }

    /// @notice Registers the launch configuration on hooks that support ILaunchHook
    /// @dev The config must be registered before the pool is initialized (the hook's beforeInitialize requires
    ///      it). Hooks without ILaunchHook support must not be given a launch config, so a mismatch reverts
    ///      instead of being silently ignored. The currency ordering is a launch-level fact this strategy
    ///      derives itself, so any caller-supplied tokenIsCurrency0 is overwritten rather than trusted.
    function _registerLaunchConfig(address hook, PoolId poolId, bytes memory launchConfig, bool tokenIsCurrency0)
        private
    {
        if (hook != address(0) && ERC165Checker.supportsInterface(hook, type(ILaunchHook).interfaceId)) {
            if (launchConfig.length == 0) revert MissingLaunchConfig();
            LaunchConfig memory config = abi.decode(launchConfig, (LaunchConfig));
            config.tokenIsCurrency0 = tokenIsCurrency0;
            ILaunchHook(hook).setLaunchConfig(poolId, config);
        } else if (launchConfig.length != 0) {
            revert UnexpectedLaunchConfig();
        }
    }

    /// @notice Low level function to transfer tokens to a recipient
    function _sweepToken(Currency token, address recipient, uint256 amount) private {
        if (amount == 0) return;
        token.transfer(recipient, amount);
        emit TokensSwept(recipient, amount);
    }

    /// @notice Receive native currency returned by the position plan's TAKE_PAIR
    receive() external payable {}
}
