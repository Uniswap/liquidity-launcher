// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {InitializerHook} from "./InitializerHook.sol";
import {IDynamicFeeModule} from "../../interfaces/IDynamicFeeModule.sol";
import {
    IBondingCurveLaunchHook,
    BondingCurveHookConfig,
    BondingCurvePhase
} from "../../interfaces/IBondingCurveLaunchHook.sol";
import {PositionPlanner} from "../../libraries/PositionPlanner.sol";
import {Plan, Position, CurrencyAmounts} from "../../types/PositionPlannerTypes.sol";

/// @title BondingCurveLaunchHook
/// @notice Single-purpose v4 hook for a native-ETH bonding-curve launch that graduates in place.
/// @dev Native ETH is always currency0 and the token always currency1, so buys are `zeroForOne` and
///      walk the price DOWN from the initial tick to the graduation tick. The hook owns the curve NFT
///      and the graduation reserve, gates liquidity by phase, applies a baked-in decaying launch fee,
///      and — on the swap that completes the curve — atomically burns the curve position and mints a
///      permanent full-range position pairing the accumulated ETH with the reserve.
/// @custom:security-contact security@uniswap.org
contract BondingCurveLaunchHook is InitializerHook, BlockNumberish, IBondingCurveLaunchHook {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice Sink for burned tokens (unrecoverable).
    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice LP fee applied when no fee module is configured and after graduation, in pips.
    /// @dev Matches the pre-rearch `baseFee: 0`.
    uint24 public constant BASE_FEE = 0;

    /// @inheritdoc IBondingCurveLaunchHook
    IPositionManager public immutable override positionManager;

    /// @notice Per-pool curve lifecycle state. All three fields are 1:1 with the pool's single curve and
    ///         are packed into one storage slot (8 + 48 + 96 = 152 bits): the hot swap paths read
    ///         phase+tokenId (Active) and phase+graduationBlock (Graduated) in a single SLOAD.
    /// @param phase The current lifecycle phase.
    /// @param graduationBlock The block the pool graduated in; 0 before graduation.
    /// @param curveTokenId The v4 PositionManager NFT id of the curve position; 0 before seeding.
    struct CurveState {
        BondingCurvePhase phase;
        uint48 graduationBlock;
        uint96 curveTokenId;
    }

    /// @notice The curve configuration registered for each pool.
    mapping(PoolId poolId => BondingCurveHookConfig config) internal _launchConfigs;
    /// @notice Packed lifecycle state for each pool.
    mapping(PoolId poolId => CurveState state) internal _curveState;

    constructor(IPoolManager _poolManager, IPositionManager _positionManager, address _authorized)
        InitializerHook(_poolManager, _authorized)
    {
        if (address(_positionManager) == address(0)) revert ZeroAddress();
        positionManager = _positionManager;
    }

    /// @inheritdoc IBondingCurveLaunchHook
    function configure(PoolId poolId, BondingCurveHookConfig calldata config) external override {
        if (msg.sender != authorized) revert NotAuthorized(msg.sender, authorized);
        if (_curveState[poolId].phase != BondingCurvePhase.Unconfigured) revert AlreadyConfigured(poolId);
        if (
            config.reserveTokenAmount == 0 || config.finalPositionRecipient == address(0)
                || config.curveTickLower >= config.curveTickUpper
                || config.graduationSqrtPriceX96 != TickMath.getSqrtPriceAtTick(config.curveTickLower)
        ) revert InvalidBondingCurveConfig();

        _launchConfigs[poolId] = config;
        _curveState[poolId].phase = BondingCurvePhase.Seeding;
        emit BondingCurveConfigured(poolId, config);
    }

    /// @inheritdoc IBondingCurveLaunchHook
    function bondingCurveConfig(PoolId poolId) external view returns (BondingCurveHookConfig memory) {
        return _launchConfigs[poolId];
    }

    /// @inheritdoc IBondingCurveLaunchHook
    function bondingCurvePhase(PoolId poolId) external view override returns (BondingCurvePhase) {
        return _curveState[poolId].phase;
    }

    /// @inheritdoc IBondingCurveLaunchHook
    function curveTokenId(PoolId poolId) external view override returns (uint256) {
        return _curveState[poolId].curveTokenId;
    }

    /// @inheritdoc IBondingCurveLaunchHook
    function graduationBlock(PoolId poolId) external view override returns (uint48) {
        return _curveState[poolId].graduationBlock;
    }

    /// @inheritdoc InitializerHook
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

    /// @dev Restricts initialization to the authorized launcher (via InitializerHook) and pins the
    ///      opening price to the curve's initial tick.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        bytes4 selector = super._beforeInitialize(sender, key, sqrtPriceX96);
        BondingCurveHookConfig storage config = _launchConfigs[key.toId()];
        if (sqrtPriceX96 != TickMath.getSqrtPriceAtTick(config.curveTickUpper)) revert InvalidBondingCurveConfig();
        return selector;
    }

    /// @dev Phase-gated liquidity. Only the hook-owned curve seed (Seeding) and the graduation
    ///      full-range mint (Graduating) may add liquidity; post-graduation the pool is open.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        PoolId poolId = key.toId();
        CurveState storage state = _curveState[poolId];
        BondingCurvePhase phase = state.phase;
        BondingCurveHookConfig storage config = _launchConfigs[poolId];

        // Liquidity cannot be added before graduation.
        if (phase == BondingCurvePhase.Unconfigured || phase == BondingCurvePhase.Active) {
            revert InvalidBondingCurvePhase(phase);
        }

        if (phase == BondingCurvePhase.Seeding) {
            if (
                params.liquidityDelta <= 0 || params.tickLower != config.curveTickLower
                    || params.tickUpper != config.curveTickUpper
            ) revert InvalidCurvePosition();
            if (sender != address(positionManager)) revert InvalidPositionManager(sender);
            uint256 nextTokenId = positionManager.nextTokenId();
            if (nextTokenId == 0) revert InvalidCurvePositionOwner();
            uint256 tokenId = nextTokenId - 1;
            if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) {
                revert InvalidCurvePositionOwner();
            }
            state.curveTokenId = SafeCastLib.toUint96(tokenId);
            state.phase = BondingCurvePhase.Active;
        } else if (phase == BondingCurvePhase.Graduating) {
            if (
                params.liquidityDelta <= 0 || params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                    || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
            ) revert InvalidFinalPosition();
            if (sender != address(positionManager)) revert InvalidPositionManager(sender);
            state.phase = BondingCurvePhase.Graduated;
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Enforces the swap-start block, quotes the decaying launch fee, and bounds buys to the
    ///      remaining curve. The hook's own graduation-normalization swap bypasses every gate.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        CurveState storage state = _curveState[poolId];
        BondingCurvePhase phase = state.phase;

        if (phase != BondingCurvePhase.Active) {
            // Block swaps before the curve is active or graduated.
            if (phase != BondingCurvePhase.Graduated) revert InvalidBondingCurvePhase(phase);
            // Block swaps in the same block as the graduation.
            if (_getBlockNumberish() == state.graduationBlock) revert SwapsBlockedInGraduationBlock(poolId);
            // Return the zero delta and the base fee with override flag.
            return
                (
                    IHooks.beforeSwap.selector,
                    BeforeSwapDeltaLibrary.ZERO_DELTA,
                    BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG
                );
        }

        BondingCurveHookConfig storage config = _launchConfigs[poolId];
        uint256 currentBlock = _getBlockNumberish();
        if (currentBlock < config.swapStartBlock) revert SwapsNotStarted(config.swapStartBlock, currentBlock);

        _validateBuyWithinCurve(poolId, params, config);

        uint24 fee = _moduleFee(config.module, key, params.zeroForOne);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Quotes the LP fee from the configured fee module for the swap's direction.
    /// @dev A module failure reverts the swap. With no module, the base fee applies.
    function _moduleFee(address module, PoolKey calldata key, bool zeroForOne) private view returns (uint24) {
        if (module == address(0)) return BASE_FEE;
        (uint24 zeroForOneFee, uint24 oneForZeroFee) = IDynamicFeeModule(module).getFee(key);
        uint24 fee = zeroForOne ? zeroForOneFee : oneForZeroFee;
        return fee > LPFeeLibrary.MAX_LP_FEE ? LPFeeLibrary.MAX_LP_FEE : fee;
    }

    /// @dev Bounds an exact-output buy so it cannot request more token than the curve still holds.
    ///      Exact-input buys are left to v4's native partial-fill-at-boundary behavior.
    function _validateBuyWithinCurve(PoolId poolId, SwapParams calldata params, BondingCurveHookConfig storage config)
        private
        view
    {
        // token is currency1, so a buy (ETH -> token) is zeroForOne.
        bool isBuy = params.zeroForOne;
        if (!isBuy || params.amountSpecified <= 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = positionManager.getPositionLiquidity(_curveState[poolId].curveTokenId);
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(config.curveTickUpper);
        // Clamp spot to the initial price so a mid-curve quote never counts token above the start.
        uint256 available = SqrtPriceMath.getAmount1Delta(
            config.graduationSqrtPriceX96,
            sqrtPriceX96 > initialSqrtPriceX96 ? initialSqrtPriceX96 : sqrtPriceX96,
            liquidity,
            false
        );
        if (uint256(params.amountSpecified) > available) {
            revert ExactOutputExceedsCurve(uint256(params.amountSpecified), available);
        }
    }

    /// @dev On the buy that completes the curve, graduate atomically inside the swapper's unlock.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        CurveState storage state = _curveState[poolId];
        // No-op in all phases except active bonding curve.
        if (state.phase != BondingCurvePhase.Active) return (IHooks.afterSwap.selector, 0);
        // Only a buy (zeroForOne) can complete the curve by pushing price down to graduation.
        if (!params.zeroForOne) return (IHooks.afterSwap.selector, 0);

        uint160 _graduationSqrtPriceX96 = _launchConfigs[poolId].graduationSqrtPriceX96;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 > _graduationSqrtPriceX96) return (IHooks.afterSwap.selector, 0);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity != 0) revert InvalidGraduationLiquidity(liquidity);

        state.phase = BondingCurvePhase.Graduating;
        emit GraduationStarted(poolId);

        // If the completing buy overshot the boundary, walk the (now empty) range back to grad price.
        // v4 skips a hook's own beforeSwap/afterSwap on self-calls (Hooks.beforeSwap/afterSwap return early
        // when msg.sender == the hook), so this swap neither re-runs the phase gate nor re-enters graduation.
        if (sqrtPriceX96 != _graduationSqrtPriceX96) {
            _normalizePrice(key, _graduationSqrtPriceX96);
            (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 != _graduationSqrtPriceX96) {
                revert InvalidGraduationPrice(sqrtPriceX96, _graduationSqrtPriceX96);
            }
        }

        _graduate(key, poolId);
        // Stamp the graduation block so _beforeSwap can reject any later swap in this same block.
        state.graduationBlock = uint48(_getBlockNumberish());
        return (IHooks.afterSwap.selector, 0);
    }

    function _graduate(PoolKey calldata key, PoolId poolId) private {
        _assertPositionManagerDeltasCleared(key);
        uint256 tokenId = _curveState[poolId].curveTokenId;
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert InvalidCurvePositionOwner();

        BondingCurveHookConfig memory config = _launchConfigs[poolId];
        uint128 curveLiquidity = positionManager.getPositionLiquidity(tokenId);
        Position[] memory positions = _resolveFinalPosition(key, config, curveLiquidity);
        if (positions[0].liquidity == 0) revert InvalidFinalPosition();

        // token (currency1) is transferred into the PositionManager and settled inside the plan.
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        token.safeTransfer(address(positionManager), config.reserveTokenAmount);
        uint256 finalTokenId = positionManager.nextTokenId();

        Plan memory plan = PositionPlanner.toPlan(positions, key, config.finalPositionRecipient);

        // Replace TAKE_PAIR so surplus ETH goes to the LP recipient while surplus token is burned.
        uint256 takePairIndex = plan.actions.length - 1;
        plan.actions[takePairIndex] = bytes1(uint8(Actions.TAKE));
        plan.params[takePairIndex] =
            abi.encode(key.currency0, config.finalPositionRecipient, ActionConstants.OPEN_DELTA);

        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), plan.actions, uint8(Actions.TAKE));
        bytes[] memory params = new bytes[](plan.params.length + 2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        for (uint256 i; i < plan.params.length; i++) {
            params[i + 1] = plan.params[i];
        }
        params[params.length - 1] = abi.encode(key.currency1, BURN_ADDRESS, ActionConstants.OPEN_DELTA);

        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
        _assertPositionManagerDeltasCleared(key);

        uint256 remaining = token.balanceOf(address(this));
        if (remaining != 0) token.safeTransfer(BURN_ADDRESS, remaining);
        emit Graduated(poolId, tokenId, finalTokenId, positions[0].liquidity);
    }

    /// @dev The completed curve's ETH (currency0) principal is fixed by the burned position's
    ///      liquidity, not spot price; it pairs with the reserve into a full-range position at grad.
    function _resolveFinalPosition(PoolKey calldata key, BondingCurveHookConfig memory config, uint128 curveLiquidity)
        private
        view
        returns (Position[] memory positions)
    {
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(config.curveTickUpper);
        uint256 principal =
            SqrtPriceMath.getAmount0Delta(config.graduationSqrtPriceX96, initialSqrtPriceX96, curveLiquidity, false);
        positions = new Position[](1);
        positions[0] = PositionPlanner.resolvePosition(
            PositionPlanner.TickBounds({
                lowerTick: TickMath.minUsableTick(key.tickSpacing), upperTick: TickMath.maxUsableTick(key.tickSpacing)
            }),
            config.graduationSqrtPriceX96,
            Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing),
            CurrencyAmounts({amount0: principal, amount1: config.reserveTokenAmount}),
            config.finalPositionRecipient
        );
    }

    function _assertPositionManagerDeltasCleared(PoolKey calldata key) private view {
        _assertPositionManagerDeltaCleared(key.currency0);
        _assertPositionManagerDeltaCleared(key.currency1);
    }

    function _assertPositionManagerDeltaCleared(Currency currency) private view {
        int256 delta = poolManager.currencyDelta(address(positionManager), currency);
        if (delta != 0) revert UnexpectedPositionManagerDelta(currency, delta);
    }

    /// @dev Empty-range traversal to restore the boundary price without moving either currency.
    function _normalizePrice(PoolKey calldata key, uint160 graduationSqrtPriceX96) private {
        // Price is at/below grad with zero liquidity; a oneForZero (price up) empty swap pins it to grad.
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1, sqrtPriceLimitX96: graduationSqrtPriceX96}),
            bytes("")
        );
        if (BalanceDelta.unwrap(delta) != 0) revert NonzeroNormalizationDelta();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override(InitializerHook, IERC165) returns (bool) {
        return interfaceId == type(IBondingCurveLaunchHook).interfaceId || super.supportsInterface(interfaceId);
    }
}
