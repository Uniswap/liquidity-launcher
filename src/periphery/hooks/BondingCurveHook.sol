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
import {IBondingCurveHook, BondingCurveConfig} from "../../interfaces/IBondingCurveHook.sol";
import {CurvePhase} from "../../types/CurvePhase.sol";
import {PositionPlanner} from "../../libraries/PositionPlanner.sol";
import {Position, CurrencyAmounts} from "../../types/PositionPlannerTypes.sol";

/// @title BondingCurveHook
/// @notice Single-purpose v4 hook for a native-ETH bonding-curve launch that graduates in place.
/// @dev Native ETH is always currency0 and the token always currency1, so buys are `zeroForOne` and
///      walk the price DOWN from the initial tick to the graduation tick. The hook owns the curve NFT
///      and the graduation reserve, gates liquidity by phase, applies a baked-in decaying launch fee,
///      and — on the swap that completes the curve — atomically burns the curve position and mints a
///      permanent full-range position pairing the accumulated ETH with the reserve.
/// @custom:security-contact security@uniswap.org
contract BondingCurveHook is InitializerHook, BlockNumberish, IBondingCurveHook {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice Launch fee at `swapStartBlock`, in pips (99%). Decays linearly to zero.
    uint24 public constant START_FEE = 990_000;
    /// @notice Launch fee once the decay window has elapsed, in pips.
    uint24 public constant END_FEE = 0;
    /// @notice Number of blocks over which the launch fee decays from START_FEE to END_FEE.
    uint256 public constant DECAY_BLOCKS = 5;
    /// @notice LP fee applied outside the launch decay window (during and after graduation), in pips.
    /// @dev Matches the pre-rearch `baseFee: 0` — the launch fee decays to this and stays here.
    uint24 public constant BASE_FEE = 0;

    /// @inheritdoc IBondingCurveHook
    IPositionManager public immutable override positionManager;

    mapping(PoolId poolId => BondingCurveConfig config) internal _configs;
    /// @inheritdoc IBondingCurveHook
    mapping(PoolId poolId => CurvePhase phase) public override phase;
    /// @inheritdoc IBondingCurveHook
    mapping(PoolId poolId => uint256 tokenId) public override curveTokenId;

    constructor(IPoolManager _poolManager, IPositionManager _positionManager, address _authorized)
        InitializerHook(_poolManager, _authorized)
    {
        if (address(_positionManager) == address(0)) revert ZeroAddress();
        positionManager = _positionManager;
    }

    /// @inheritdoc IBondingCurveHook
    function configure(PoolId poolId, BondingCurveConfig calldata config) external override {
        if (msg.sender != authorized) revert NotAuthorized(msg.sender, authorized);
        if (phase[poolId] != CurvePhase.Unconfigured) revert AlreadyConfigured(poolId);
        if (
            config.reserveTokenAmount == 0 || config.finalPositionRecipient == address(0)
                || config.curveTickLower >= config.curveTickUpper
                || config.graduationSqrtPriceX96 != TickMath.getSqrtPriceAtTick(config.curveTickLower)
        ) revert InvalidCurveConfig();

        _configs[poolId] = config;
        phase[poolId] = phase[poolId].advanceTo(CurvePhase.Seeding);
        emit CurveConfigured(poolId, config);
    }

    /// @inheritdoc IBondingCurveHook
    function curveConfig(PoolId poolId) external view returns (BondingCurveConfig memory) {
        return _configs[poolId];
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
        BondingCurveConfig storage config = _configs[key.toId()];
        if (sqrtPriceX96 != TickMath.getSqrtPriceAtTick(config.curveTickUpper)) revert InvalidCurveConfig();
        return selector;
    }

    /// @dev Phase-gated liquidity. Only the hook-owned curve seed (Seeding) and the graduation
    ///      full-range mint (Graduating) may add liquidity; post-graduation the pool is open.
    function _beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        CurvePhase current = phase[poolId];
        BondingCurveConfig storage config = _configs[poolId];

        if (current == CurvePhase.Seeding) {
            if (
                params.liquidityDelta <= 0 || params.tickLower != config.curveTickLower
                    || params.tickUpper != config.curveTickUpper
            ) revert InvalidCurvePosition();
            if (sender != address(positionManager)) revert InvalidPositionManager(sender);
            uint256 nextTokenId = positionManager.nextTokenId();
            if (nextTokenId == 0) revert InvalidCurvePositionOwner();
            uint256 tokenId = nextTokenId - 1;
            if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert InvalidCurvePositionOwner();
            curveTokenId[poolId] = tokenId;
            phase[poolId] = current.advanceTo(CurvePhase.Active);
        } else if (current == CurvePhase.Graduating) {
            if (
                params.liquidityDelta <= 0 || params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                    || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
            ) revert InvalidFinalPosition();
            if (sender != address(positionManager)) revert InvalidPositionManager(sender);
            phase[poolId] = current.advanceTo(CurvePhase.Graduated);
        } else if (current != CurvePhase.Graduated) {
            revert InvalidPhaseForSwap(current);
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev Enforces the swap-start block, quotes the decaying launch fee, and bounds buys to the
    ///      remaining curve. The hook's own graduation-normalization swap bypasses every gate.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // The graduation-normalization swap originates from this hook; it must never be gated.
        if (sender == address(this)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        PoolId poolId = key.toId();
        CurvePhase current = phase[poolId];
        if (current == CurvePhase.Graduated) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }
        if (current != CurvePhase.Active) revert InvalidPhaseForSwap(current);

        BondingCurveConfig storage config = _configs[poolId];
        uint256 currentBlock = _getBlockNumberish();
        if (currentBlock < config.swapStartBlock) revert SwapsNotStarted(config.swapStartBlock, currentBlock);

        _validateBuyWithinCurve(poolId, params, config);

        uint24 fee = _launchFee(currentBlock - config.swapStartBlock);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @notice Linear fee decay from START_FEE to END_FEE over DECAY_BLOCKS.
    function _launchFee(uint256 elapsed) private pure returns (uint24) {
        if (elapsed >= DECAY_BLOCKS) return END_FEE;
        return uint24(START_FEE - (uint256(START_FEE - END_FEE) * elapsed) / DECAY_BLOCKS);
    }

    /// @dev Bounds an exact-output buy so it cannot request more token than the curve still holds.
    ///      Exact-input buys are left to v4's native partial-fill-at-boundary behavior.
    function _validateBuyWithinCurve(PoolId poolId, SwapParams calldata params, BondingCurveConfig storage config)
        private
        view
    {
        // token is currency1, so a buy (ETH -> token) is zeroForOne.
        bool isBuy = params.zeroForOne;
        if (!isBuy || params.amountSpecified <= 0) return;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = positionManager.getPositionLiquidity(curveTokenId[poolId]);
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
        if (phase[poolId] != CurvePhase.Active) return (IHooks.afterSwap.selector, 0);
        // Only a buy (zeroForOne) can complete the curve by pushing price down to graduation.
        if (!params.zeroForOne) return (IHooks.afterSwap.selector, 0);

        BondingCurveConfig storage config = _configs[poolId];
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 > config.graduationSqrtPriceX96) return (IHooks.afterSwap.selector, 0);

        uint128 liquidity = poolManager.getLiquidity(poolId);
        if (liquidity != 0) revert InvalidGraduationLiquidity(liquidity);

        phase[poolId] = phase[poolId].advanceTo(CurvePhase.Graduating);
        emit GraduationStarted(poolId);

        // If the completing buy overshot the boundary, walk the (now empty) range back to grad price.
        // This swap re-enters _beforeSwap as sender == address(this), which bypasses the phase gate.
        if (sqrtPriceX96 != config.graduationSqrtPriceX96) {
            _normalizePrice(key, config.graduationSqrtPriceX96);
            (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 != config.graduationSqrtPriceX96) {
                revert InvalidGraduationPrice(sqrtPriceX96, config.graduationSqrtPriceX96);
            }
        }

        _graduate(key, poolId, config);
        return (IHooks.afterSwap.selector, 0);
    }

    function _graduate(PoolKey calldata key, PoolId poolId, BondingCurveConfig storage config) private {
        _assertDeltasCleared(key);
        uint256 tokenId = curveTokenId[poolId];
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert InvalidCurvePositionOwner();

        uint128 curveLiquidity = positionManager.getPositionLiquidity(tokenId);
        Position memory finalPosition = _resolveFinalPosition(key, config, curveLiquidity);
        if (finalPosition.liquidity == 0) revert InvalidFinalPosition();

        // token (currency1) is transferred into the PositionManager and settled inside the plan.
        IERC20 token = IERC20(Currency.unwrap(key.currency1));
        token.safeTransfer(address(positionManager), config.reserveTokenAmount);
        uint256 finalTokenId = positionManager.nextTokenId();
        (bytes memory actions, bytes[] memory planParams) = _graduationPlan(key, tokenId, finalPosition, config.finalPositionRecipient);
        positionManager.modifyLiquiditiesWithoutUnlock(actions, planParams);
        _assertDeltasCleared(key);

        uint256 remaining = token.balanceOf(address(this));
        if (remaining != 0) token.safeTransfer(BURN_ADDRESS, remaining);
        emit Graduated(poolId, tokenId, finalTokenId, finalPosition.liquidity);
    }

    /// @dev The completed curve's ETH (currency0) principal is fixed by the burned position's
    ///      liquidity, not spot price; it pairs with the reserve into a full-range position at grad.
    function _resolveFinalPosition(PoolKey calldata key, BondingCurveConfig storage config, uint128 curveLiquidity)
        private
        view
        returns (Position memory)
    {
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(config.curveTickUpper);
        uint256 principal = SqrtPriceMath.getAmount0Delta(config.graduationSqrtPriceX96, initialSqrtPriceX96, curveLiquidity, false);
        return PositionPlanner.resolvePosition(
            PositionPlanner.TickBounds({
                lowerTick: TickMath.minUsableTick(key.tickSpacing),
                upperTick: TickMath.maxUsableTick(key.tickSpacing)
            }),
            config.graduationSqrtPriceX96,
            Pool.tickSpacingToMaxLiquidityPerTick(key.tickSpacing),
            CurrencyAmounts({amount0: principal, amount1: config.reserveTokenAmount}),
            config.finalPositionRecipient
        );
    }

    function _graduationPlan(PoolKey calldata key, uint256 tokenId, Position memory finalPosition, address recipient)
        private
        pure
        returns (bytes memory actions, bytes[] memory planParams)
    {
        actions = abi.encodePacked(
            uint8(Actions.BURN_POSITION),
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.TAKE),
            uint8(Actions.TAKE)
        );
        planParams = new bytes[](6);
        planParams[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        planParams[1] = abi.encode(
            key,
            finalPosition.tickLower,
            finalPosition.tickUpper,
            finalPosition.liquidity,
            SafeCastLib.toUint128(finalPosition.amount0),
            SafeCastLib.toUint128(finalPosition.amount1),
            finalPosition.recipient,
            bytes("")
        );
        planParams[2] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        planParams[3] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        // Surplus ETH (currency0) to the LP recipient; surplus token (currency1) is burned.
        planParams[4] = abi.encode(key.currency0, recipient, ActionConstants.OPEN_DELTA);
        planParams[5] = abi.encode(key.currency1, BURN_ADDRESS, ActionConstants.OPEN_DELTA);
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

    function _assertDeltasCleared(PoolKey calldata key) private view {
        if (poolManager.currencyDelta(address(positionManager), key.currency0) != 0) {
            revert UnexpectedPositionManagerDelta(Currency.unwrap(key.currency0), poolManager.currencyDelta(address(positionManager), key.currency0));
        }
        if (poolManager.currencyDelta(address(positionManager), key.currency1) != 0) {
            revert UnexpectedPositionManagerDelta(Currency.unwrap(key.currency1), poolManager.currencyDelta(address(positionManager), key.currency1));
        }
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override(InitializerHook, IERC165) returns (bool) {
        return interfaceId == type(IBondingCurveHook).interfaceId || super.supportsInterface(interfaceId);
    }
}
