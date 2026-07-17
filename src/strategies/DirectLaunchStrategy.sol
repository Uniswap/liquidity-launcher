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
/// @notice Launches a token directly into a new v4 pool as single-sided liquidity
/// @dev The caller controls the pool, positions, recipients, hook, and launch configuration. Unplaced tokens are
/// swept to the configured recipient.
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

    /// @notice Initializes a pool and mints its token-side positions
    /// @dev The caller must approve `totalSupply` tokens. Fee-on-transfer and rebasing tokens are not supported.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        virtual
        override
        nonReentrant
    {
        _validateTokenAmount(token, totalSupply);
        DirectLaunchParameters memory params = abi.decode(configData, (DirectLaunchParameters));
        (PoolKey memory key, bool tokenIsCurrency0) = _prepareLaunch(token, totalSupply, params);
        uint256 balanceBefore = _pullTokenExact(token, msg.sender, totalSupply);
        _executeLaunch(token, totalSupply, params, balanceBefore, key, tokenIsCurrency0);
    }

    /// @notice Pulls an exact token amount without consuming a preexisting balance
    /// @param token The launched token
    /// @param from The account funding the launch
    /// @param amount The exact amount to pull
    /// @return balanceBefore This contract's token balance before the transfer
    function _pullTokenExact(address token, address from, uint256 amount) internal returns (uint256 balanceBefore) {
        _validateTokenAmount(token, amount);
        Currency tokenCurrency = Currency.wrap(token);
        balanceBefore = tokenCurrency.balanceOfSelf();
        SafeERC20.safeTransferFrom(IERC20(token), from, address(this), amount);

        uint256 balanceAfter = tokenCurrency.balanceOfSelf();
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (received != amount) revert TokenAmountMismatch(received, amount);
    }

    /// @notice Initializes a pool and mints positions from tokens already held by this contract
    /// @dev `balanceBefore` protects any preexisting token balance from the launch and sweep.
    /// @return poolId The initialized pool ID
    /// @return key The initialized pool key
    /// @return plan The executed PositionManager plan
    function _launch(address token, uint256 totalSupply, DirectLaunchParameters memory params, uint256 balanceBefore)
        internal
        virtual
        returns (PoolId poolId, PoolKey memory key, bytes memory plan)
    {
        bool tokenIsCurrency0;
        (key, tokenIsCurrency0) = _prepareLaunch(token, totalSupply, params);
        (poolId, plan) = _executeLaunch(token, totalSupply, params, balanceBefore, key, tokenIsCurrency0);
    }

    /// @notice Validates a launch and registers its hook configuration
    /// @return key The validated pool key
    /// @return tokenIsCurrency0 Whether the launched token is currency0
    function _prepareLaunch(address token, uint256 totalSupply, DirectLaunchParameters memory params)
        internal
        virtual
        returns (PoolKey memory key, bool tokenIsCurrency0)
    {
        _validateTokenAmount(token, totalSupply);

        Currency tokenCurrency = Currency.wrap(token);
        tokenIsCurrency0 = tokenCurrency < Currency.wrap(params.currency);
        params.validate(token, tokenIsCurrency0);

        key = PoolKey({
            currency0: tokenIsCurrency0 ? tokenCurrency : Currency.wrap(params.currency),
            currency1: tokenIsCurrency0 ? Currency.wrap(params.currency) : tokenCurrency,
            fee: params.poolParameters.fee,
            tickSpacing: params.poolParameters.tickSpacing,
            hooks: IHooks(params.poolParameters.hook)
        });
        PoolId poolId = key.toId();
        params.poolParameters.hook.validateHook(params.poolParameters.fee, poolId, poolManager);
        _registerLaunchConfig(params.poolParameters.hook, poolId, params.launchConfig, tokenIsCurrency0);
    }

    /// @notice Initializes a prepared pool and mints its positions
    function _executeLaunch(
        address token,
        uint256 totalSupply,
        DirectLaunchParameters memory params,
        uint256 balanceBefore,
        PoolKey memory key,
        bool tokenIsCurrency0
    ) internal virtual returns (PoolId poolId, bytes memory plan) {
        Currency tokenCurrency = Currency.wrap(token);
        poolId = key.toId();

        uint256 balance = tokenCurrency.balanceOfSelf();
        uint256 available = balance >= balanceBefore ? balance - balanceBefore : 0;
        if (available != totalSupply) revert TokenAmountMismatch(available, totalSupply);

        poolManager.initialize(key, params.initialSqrtPriceX96);

        plan = _mintPositions(key, tokenCurrency, tokenIsCurrency0, SafeCastLib.toUint128(totalSupply), params);

        // Return rounding dust and any supply limited by per-tick liquidity caps.
        balance = tokenCurrency.balanceOfSelf();
        uint256 unplaced = balance >= balanceBefore ? balance - balanceBefore : 0;
        _sweepToken(tokenCurrency, params.recipient, unplaced);

        emit TokenLaunched(poolId, token, key, params.initialSqrtPriceX96, plan);
    }

    /// @notice Validates the launched token and amount against v4 delta limits
    function _validateTokenAmount(address token, uint256 amount) internal pure {
        // Native ETH is supported as the pool currency, but not as the launched token.
        if (token == address(0)) revert ZeroAddressToken();
        // PoolManager represents currency deltas as int128.
        if (amount == 0 || amount > uint128(type(int128).max)) {
            revert InvalidAmount(amount, uint128(type(int128).max));
        }
    }

    /// @notice Builds and executes the PositionManager mint plan
    /// @return plan The encoded PositionManager plan that was executed
    function _mintPositions(
        PoolKey memory key,
        Currency tokenCurrency,
        bool tokenIsCurrency0,
        uint128 tokenAmount,
        DirectLaunchParameters memory params
    ) internal virtual returns (bytes memory plan) {
        uint128 tokenTransferAmount;
        (plan, tokenTransferAmount) = _createPositionPlan(key, tokenIsCurrency0, tokenAmount, params);
        tokenCurrency.transfer(address(positionManager), tokenTransferAmount);
        positionManager.modifyLiquidities(plan, block.timestamp);
    }

    /// @notice Builds the single-sided PositionManager plan
    /// @dev The plan has no pool-currency budget. Each position must therefore be entirely token-side.
    /// @param key The pool key for the launch
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
    ) internal pure virtual returns (bytes memory plan, uint128 tokenTransferAmount) {
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

    /// @notice Registers configuration on hooks that support ILaunchHook
    /// @dev The strategy derives and overwrites `tokenIsCurrency0`. A launch config is required for ILaunchHook
    /// hooks and rejected for all other hooks.
    function _registerLaunchConfig(address hook, PoolId poolId, bytes memory launchConfig, bool tokenIsCurrency0)
        internal
        virtual
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

    /// @notice Transfers unplaced tokens to a recipient
    function _sweepToken(Currency token, address recipient, uint256 amount) internal virtual {
        if (amount == 0) return;
        token.transfer(recipient, amount);
        emit TokensSwept(recipient, amount);
    }

    /// @notice Receives native currency returned by the PositionManager plan
    receive() external payable {}
}
