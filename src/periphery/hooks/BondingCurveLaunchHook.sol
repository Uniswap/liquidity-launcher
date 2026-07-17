// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {LaunchHook} from "./LaunchHook.sol";
import {LaunchConfig} from "../../interfaces/ILaunchHook.sol";
import {
    IBondingCurveLaunchHook,
    BondingCurveHookConfig,
    BondingCurvePhase
} from "../../interfaces/IBondingCurveLaunchHook.sol";

/// @title BondingCurveLaunchHook
/// @notice Adds a frozen keeper graduation phase to LaunchHook
contract BondingCurveLaunchHook is LaunchHook, IBondingCurveLaunchHook {
    using StateLibrary for IPoolManager;

    mapping(PoolId poolId => BondingCurveHookConfig config) internal _bondingCurveConfigs;
    mapping(PoolId poolId => BondingCurvePhase phase) public override bondingCurvePhase;

    constructor(IPoolManager _poolManager, address _authorized) LaunchHook(_poolManager, _authorized) {}

    /// @inheritdoc IBondingCurveLaunchHook
    function bondingCurveConfig(PoolId poolId) external view returns (BondingCurveHookConfig memory) {
        return _bondingCurveConfigs[poolId];
    }

    /// @inheritdoc IBondingCurveLaunchHook
    function beginGraduation(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        BondingCurveHookConfig storage config = _bondingCurveConfigs[poolId];
        if (msg.sender != config.manager) revert InvalidGraduationManager(msg.sender, config.manager);
        if (bondingCurvePhase[poolId] != BondingCurvePhase.Active) {
            revert InvalidBondingCurvePhase(bondingCurvePhase[poolId]);
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 != config.graduationSqrtPriceX96) revert GraduationNotReady();

        bondingCurvePhase[poolId] = BondingCurvePhase.Graduating;
        emit GraduationStarted(poolId);
    }

    /// @inheritdoc LaunchHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: true,
            beforeSwap: true,
            beforeSwapReturnDelta: false,
            afterSwap: false,
            afterInitialize: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _afterSetLaunchConfig(PoolId poolId, LaunchConfig calldata launchConfig) internal override {
        if (launchConfig.hookConfig.length == 0) revert InvalidBondingCurveConfig();
        BondingCurveHookConfig memory config = abi.decode(launchConfig.hookConfig, (BondingCurveHookConfig));
        if (
            config.manager == address(0) || config.curveTickLower >= config.curveTickUpper
                || config.graduationSqrtPriceX96
                    != TickMath.getSqrtPriceAtTick(
                        launchConfig.tokenIsCurrency0 ? config.curveTickUpper : config.curveTickLower
                    )
        ) revert InvalidBondingCurveConfig();

        _bondingCurveConfigs[poolId] = config;
        bondingCurvePhase[poolId] = BondingCurvePhase.Seeding;
        emit BondingCurveConfigured(poolId, config);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        bytes4 selector = super._beforeInitialize(sender, key, sqrtPriceX96);
        PoolId poolId = key.toId();
        BondingCurveHookConfig storage config = _bondingCurveConfigs[poolId];
        bool tokenIsCurrency0 = _launchConfigs[poolId].tokenIsCurrency0;
        int24 initialTick = tokenIsCurrency0 ? config.curveTickLower : config.curveTickUpper;
        if (sqrtPriceX96 != TickMath.getSqrtPriceAtTick(initialTick)) revert InvalidBondingCurveConfig();
        return selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        BondingCurvePhase phase = bondingCurvePhase[poolId];
        BondingCurveHookConfig storage config = _bondingCurveConfigs[poolId];

        if (phase == BondingCurvePhase.Seeding) {
            if (
                params.liquidityDelta <= 0 || params.tickLower != config.curveTickLower
                    || params.tickUpper != config.curveTickUpper
            ) revert InvalidCurvePosition();
            bondingCurvePhase[poolId] = BondingCurvePhase.Active;
        } else if (phase == BondingCurvePhase.Graduating) {
            if (
                params.liquidityDelta <= 0 || params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                    || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
            ) revert InvalidFinalPosition();
            bondingCurvePhase[poolId] = BondingCurvePhase.Graduated;
            emit GraduationCompleted(poolId);
        } else if (phase != BondingCurvePhase.Graduated) {
            revert InvalidBondingCurvePhase(phase);
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = super._beforeSwap(sender, key, params, hookData);
        _validateBondingCurveSwap(key, params);
        return (selector, delta, fee);
    }

    function _validateBondingCurveSwap(PoolKey calldata key, SwapParams calldata params) private view {
        PoolId poolId = key.toId();
        BondingCurvePhase phase = bondingCurvePhase[poolId];
        if (phase == BondingCurvePhase.Graduated) return;
        if (phase != BondingCurvePhase.Active) revert InvalidBondingCurvePhase(phase);

        BondingCurveHookConfig storage config = _bondingCurveConfigs[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == config.graduationSqrtPriceX96) revert GraduationPending();

        bool tokenIsCurrency0 = _launchConfigs[poolId].tokenIsCurrency0;
        bool isBuy = params.zeroForOne != tokenIsCurrency0;
        if (isBuy) {
            bool crossesGraduation = tokenIsCurrency0
                ? params.sqrtPriceLimitX96 > config.graduationSqrtPriceX96
                : params.sqrtPriceLimitX96 < config.graduationSqrtPriceX96;
            if (crossesGraduation) {
                revert InvalidBuyPriceLimit(params.sqrtPriceLimitX96, config.graduationSqrtPriceX96);
            }
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override(LaunchHook, IERC165) returns (bool) {
        return interfaceId == type(IBondingCurveLaunchHook).interfaceId || super.supportsInterface(interfaceId);
    }
}
