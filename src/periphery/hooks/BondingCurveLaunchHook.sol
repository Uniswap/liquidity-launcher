// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {LaunchHook} from "./LaunchHook.sol";
import {LaunchConfig} from "../../interfaces/ILaunchHook.sol";
import {
    IBondingCurveLaunchHook,
    BondingCurveHookConfig,
    BondingCurvePhase
} from "../../interfaces/IBondingCurveLaunchHook.sol";
import {PositionPlanner} from "../../libraries/PositionPlanner.sol";
import {Position, CurrencyAmounts} from "../../types/PositionPlannerTypes.sol";

/// @title BondingCurveLaunchHook
/// @notice Atomically replaces a completed finite curve with full-range liquidity
contract BondingCurveLaunchHook is LaunchHook, IBondingCurveLaunchHook {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    address internal constant BURN_ADDRESS = address(0xdead);

    /// @inheritdoc IBondingCurveLaunchHook
    IPositionManager public immutable override positionManager;

    mapping(PoolId poolId => BondingCurveHookConfig config) internal _bondingCurveConfigs;
    mapping(PoolId poolId => BondingCurvePhase phase) public override bondingCurvePhase;
    mapping(PoolId poolId => uint256 tokenId) public override curveTokenId;

    constructor(IPoolManager _poolManager, IPositionManager _positionManager, address _authorized)
        LaunchHook(_poolManager, _authorized)
    {
        // The hook must use the same PositionManager that mints the launch positions.
        if (address(_positionManager) == address(0)) revert ZeroAddress();
        positionManager = _positionManager;
    }

    /// @inheritdoc IBondingCurveLaunchHook
    function bondingCurveConfig(PoolId poolId) external view returns (BondingCurveHookConfig memory) {
        return _bondingCurveConfigs[poolId];
    }

    /// @inheritdoc LaunchHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: true,
            beforeSwap: true,
            beforeSwapReturnDelta: false,
            afterSwap: true,
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
            config.reserveTokenAmount == 0 || config.finalPositionRecipient == address(0)
                || config.curveTickLower >= config.curveTickUpper
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

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        BondingCurvePhase phase = bondingCurvePhase[poolId];
        BondingCurveHookConfig storage config = _bondingCurveConfigs[poolId];

        if (phase == BondingCurvePhase.Seeding) {
            if (
                params.liquidityDelta <= 0 || params.tickLower != config.curveTickLower
                    || params.tickUpper != config.curveTickUpper
            ) revert InvalidCurvePosition();
            // Only a hook-owned NFT minted by the configured PositionManager can activate the curve.
            if (sender != address(positionManager)) revert InvalidPositionManager(sender);
            uint256 nextTokenId = positionManager.nextTokenId();
            if (nextTokenId == 0) revert InvalidCurvePositionOwner();
            uint256 tokenId = nextTokenId - 1;
            if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) {
                revert InvalidCurvePositionOwner();
            }
            curveTokenId[poolId] = tokenId;
            bondingCurvePhase[poolId] = BondingCurvePhase.Active;
        } else if (phase == BondingCurvePhase.Graduating) {
            if (
                params.liquidityDelta <= 0 || params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                    || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
            ) revert InvalidFinalPosition();
            if (sender != address(positionManager)) revert InvalidPositionManager(sender);
            bondingCurvePhase[poolId] = BondingCurvePhase.Graduated;
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
        bool tokenIsCurrency0 = _launchConfigs[poolId].tokenIsCurrency0;
        bool isBuy = params.zeroForOne != tokenIsCurrency0;
        if (!isBuy || params.amountSpecified <= 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = positionManager.getPositionLiquidity(curveTokenId[poolId]);
        uint160 initialSqrtPriceX96 =
            TickMath.getSqrtPriceAtTick(tokenIsCurrency0 ? config.curveTickLower : config.curveTickUpper);
        uint256 available = tokenIsCurrency0
            ? SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96 < initialSqrtPriceX96 ? initialSqrtPriceX96 : sqrtPriceX96,
                config.graduationSqrtPriceX96,
                liquidity,
                false
            )
            : SqrtPriceMath.getAmount1Delta(
                config.graduationSqrtPriceX96,
                sqrtPriceX96 > initialSqrtPriceX96 ? initialSqrtPriceX96 : sqrtPriceX96,
                liquidity,
                false
            );
        uint256 requested = uint256(params.amountSpecified);
        if (requested > available) revert ExactOutputExceedsCurve(requested, available);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        if (bondingCurvePhase[poolId] != BondingCurvePhase.Active) return (IHooks.afterSwap.selector, 0);

        bool tokenIsCurrency0 = _launchConfigs[poolId].tokenIsCurrency0;
        bool isBuy = params.zeroForOne != tokenIsCurrency0;
        if (!isBuy) return (IHooks.afterSwap.selector, 0);

        BondingCurveHookConfig storage config = _bondingCurveConfigs[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        bool completed = tokenIsCurrency0
            ? sqrtPriceX96 >= config.graduationSqrtPriceX96
            : sqrtPriceX96 <= config.graduationSqrtPriceX96;
        if (!completed) return (IHooks.afterSwap.selector, 0);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity != 0) revert InvalidGraduationLiquidity(liquidity);

        bondingCurvePhase[poolId] = BondingCurvePhase.Graduating;
        emit GraduationStarted(poolId);

        if (sqrtPriceX96 != config.graduationSqrtPriceX96) {
            _normalizePrice(key, !params.zeroForOne, config.graduationSqrtPriceX96);
        }

        (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 != config.graduationSqrtPriceX96) {
            revert InvalidGraduationPrice(sqrtPriceX96, config.graduationSqrtPriceX96);
        }

        _graduate(key, poolId, config);
        if (bondingCurvePhase[poolId] != BondingCurvePhase.Graduated) revert GraduationIncomplete();
        return (IHooks.afterSwap.selector, 0);
    }

    function _graduate(PoolKey calldata key, PoolId poolId, BondingCurveHookConfig storage config) private {
        _assertPositionManagerDeltasCleared(key);
        uint256 tokenId = curveTokenId[poolId];
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) {
            revert InvalidCurvePositionOwner();
        }

        bool tokenIsCurrency0 = _launchConfigs[poolId].tokenIsCurrency0;
        uint128 curveLiquidity = positionManager.getPositionLiquidity(tokenId);
        Position memory finalPosition = _resolveFinalPosition(key, config, tokenIsCurrency0, curveLiquidity);
        if (finalPosition.liquidity == 0) revert InvalidFinalPosition();

        _replacePosition(key, poolId, tokenId, finalPosition, tokenIsCurrency0, config);
    }

    function _resolveFinalPosition(
        PoolKey calldata key,
        BondingCurveHookConfig storage config,
        bool tokenIsCurrency0,
        uint128 curveLiquidity
    ) private view returns (Position memory) {
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(
            tokenIsCurrency0 ? config.curveTickLower : config.curveTickUpper
        );
        uint256 principal = tokenIsCurrency0
            ? SqrtPriceMath.getAmount1Delta(initialSqrtPriceX96, config.graduationSqrtPriceX96, curveLiquidity, false)
            : SqrtPriceMath.getAmount0Delta(config.graduationSqrtPriceX96, initialSqrtPriceX96, curveLiquidity, false);
        CurrencyAmounts memory amounts = tokenIsCurrency0
            ? CurrencyAmounts({amount0: config.reserveTokenAmount, amount1: principal})
            : CurrencyAmounts({amount0: principal, amount1: config.reserveTokenAmount});
        return PositionPlanner.resolvePosition(
            PositionPlanner.TickBounds({
                lowerTick: TickMath.minUsableTick(key.tickSpacing), upperTick: TickMath.maxUsableTick(key.tickSpacing)
            }),
            config.graduationSqrtPriceX96,
            Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing),
            amounts,
            config.finalPositionRecipient
        );
    }

    function _replacePosition(
        PoolKey calldata key,
        PoolId poolId,
        uint256 tokenId,
        Position memory finalPosition,
        bool tokenIsCurrency0,
        BondingCurveHookConfig storage config
    ) private {
        Currency tokenCurrency = tokenIsCurrency0 ? key.currency0 : key.currency1;
        IERC20 token = IERC20(Currency.unwrap(tokenCurrency));
        token.safeTransfer(address(positionManager), config.reserveTokenAmount);
        uint256 finalTokenId = positionManager.nextTokenId();
        (bytes memory actions, bytes[] memory params) =
            _graduationPlan(key, tokenId, finalPosition, tokenIsCurrency0, config.finalPositionRecipient);
        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
        _assertPositionManagerDeltasCleared(key);

        // Forced token transfers and launch rounding dust never contribute to graduation.
        uint256 remainingToken = token.balanceOf(address(this));
        if (remainingToken != 0) token.safeTransfer(BURN_ADDRESS, remainingToken);
        emit Graduated(poolId, tokenId, finalTokenId, finalPosition.liquidity);
    }

    function _assertPositionManagerDeltasCleared(PoolKey calldata key) private view {
        _assertPositionManagerDeltaCleared(key.currency0);
        _assertPositionManagerDeltaCleared(key.currency1);
    }

    function _assertPositionManagerDeltaCleared(Currency currency) private view {
        int256 delta = poolManager.currencyDelta(address(positionManager), currency);
        if (delta != 0) revert UnexpectedPositionManagerDelta(currency, delta);
    }

    function _graduationPlan(
        PoolKey calldata key,
        uint256 tokenId,
        Position memory finalPosition,
        bool tokenIsCurrency0,
        address finalPositionRecipient
    ) private pure returns (bytes memory actions, bytes[] memory params) {
        actions = abi.encodePacked(
            uint8(Actions.BURN_POSITION),
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.TAKE),
            uint8(Actions.TAKE)
        );
        params = new bytes[](6);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(
            key,
            finalPosition.tickLower,
            finalPosition.tickUpper,
            finalPosition.liquidity,
            SafeCastLib.toUint128(finalPosition.amount0),
            SafeCastLib.toUint128(finalPosition.amount1),
            finalPosition.recipient,
            bytes("")
        );
        params[2] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        Currency tokenCurrency = tokenIsCurrency0 ? key.currency0 : key.currency1;
        Currency pairedCurrency = tokenIsCurrency0 ? key.currency1 : key.currency0;
        params[4] = abi.encode(pairedCurrency, finalPositionRecipient, ActionConstants.OPEN_DELTA);
        params[5] = abi.encode(tokenCurrency, BURN_ADDRESS, ActionConstants.OPEN_DELTA);
    }

    function _normalizePrice(PoolKey calldata key, bool zeroForOne, uint160 graduationSqrtPriceX96) private {
        // Empty-range traversal restores the boundary without transferring either currency.
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -1, sqrtPriceLimitX96: graduationSqrtPriceX96}),
            bytes("")
        );
        if (BalanceDelta.unwrap(delta) != 0) revert NonzeroNormalizationDelta();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override(LaunchHook, IERC165) returns (bool) {
        return interfaceId == type(IBondingCurveLaunchHook).interfaceId || super.supportsInterface(interfaceId);
    }
}
