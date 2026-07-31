// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IClaimExecutor} from "../../../src/interfaces/IClaimExecutor.sol";
import {IClaimableRecipient} from "../../../src/interfaces/IClaimableRecipient.sol";
import {IFeeSplitter} from "../../../src/interfaces/IFeeSplitter.sol";

/// @notice The PositionManager's WETH9 getter, which `IPositionManager` does not declare.
interface INativeWrapper {
    function WETH9() external view returns (IWETH9);
}

/// @notice The `positionManager` getter every recipient inherits from `BaseClaimRecipient`, which
///         `IClaimableRecipient` does not declare.
interface IRecipientPositionManager {
    function positionManager() external view returns (IPositionManager);
}

/// @title CompoundingClaimExecutor
/// @notice Keeper-callable executor that collects a FeeSplitter position's fees and compounds the
///         `CompoundingClaimRecipient`'s share back into that position, in a single transaction.
/// @dev `CompoundingClaimRecipient.claim` pays its caller and then calls back through `onClaimed`,
///      asserting afterwards that the position's liquidity grew by at least `MIN_LIQUIDITY_INCREASE`.
///      An EOA cannot satisfy that contract, so triggering a compound requires a deployed executor.
/// @dev Collect and compound MUST share a transaction: `FeeSplitter.increaseLiquidity` reverts with
///      `UncollectedFees` once the position has accrued anything since its last modification, so a
///      collect landed in an earlier block is already stale on any pool that trades.
/// @dev Deployment tooling, not part of the audited protocol surface. It custodies nothing between
///      transactions: everything it is paid is either compounded or swept back to the FeeSplitter.
contract CompoundingClaimExecutor is IClaimExecutor, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @notice The denominator for the liquidity buffer, in basis points
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The maximum buffer that may be withheld from the computed liquidity: 1%
    uint256 public constant MAX_LIQUIDITY_BUFFER_BPS = 100;

    /// @notice Thrown when the recipient is bound to a different PositionManager than the FeeSplitter
    error PositionManagerMismatch(address expected, address actual);

    /// @notice Thrown when the liquidity buffer exceeds `MAX_LIQUIDITY_BUFFER_BPS`
    error LiquidityBufferTooLarge(uint256 bufferBps);

    /// @notice Thrown when `onClaimed` is called by anything other than the configured recipient
    error NotRecipient(address caller);

    /// @notice Thrown when `onClaimed` is reached outside of a `collectAndCompound` call
    error NoCompoundInProgress();

    /// @notice Thrown when the recipient calls back for a position other than the one being compounded
    error TokenIdMismatch(uint256 expected, uint256 actual);

    /// @notice Emitted once per compounded position
    /// @param tokenId The position compounded
    /// @param currency0Compounded The currency0 amount claimed from the recipient
    /// @param currency1Compounded The currency1 amount claimed from the recipient
    /// @param liquidityAdded The liquidity the position gained
    event Compounded(
        uint256 indexed tokenId, uint256 currency0Compounded, uint256 currency1Compounded, uint256 liquidityAdded
    );

    /// @notice The canonical v4 PositionManager
    IPositionManager public immutable positionManager;

    /// @notice The PoolManager the PositionManager is bound to
    IPoolManager public immutable poolManager;

    /// @notice The WETH9 the PositionManager unwraps, read from the PositionManager itself
    IWETH9 public immutable weth9;

    /// @notice The FeeSplitter custodying the positions this executor compounds
    IFeeSplitter public immutable feeSplitter;

    /// @notice The recipient holding the compounding share of collected fees
    IClaimableRecipient public immutable recipient;

    /// @notice Basis points withheld from the computed liquidity, absorbing the rounding between
    ///         `getLiquidityForAmounts` and the amounts the pool charges for that liquidity
    uint256 public immutable liquidityBufferBps;

    /// @notice The position being compounded, offset by one so that zero means "no compound in progress"
    uint256 private _activeTokenIdPlusOne;

    /// @param _feeSplitter The FeeSplitter that owns the positions to compound
    /// @param _recipient The `CompoundingClaimRecipient` receiving a callback-enabled split
    /// @param _liquidityBufferBps Basis points to withhold from the computed liquidity
    constructor(IFeeSplitter _feeSplitter, IClaimableRecipient _recipient, uint256 _liquidityBufferBps) {
        if (_liquidityBufferBps > MAX_LIQUIDITY_BUFFER_BPS) revert LiquidityBufferTooLarge(_liquidityBufferBps);

        IPositionManager _positionManager = _feeSplitter.positionManager();
        address recipientPositionManager = address(IRecipientPositionManager(address(_recipient)).positionManager());
        if (recipientPositionManager != address(_positionManager)) {
            revert PositionManagerMismatch(address(_positionManager), recipientPositionManager);
        }

        positionManager = _positionManager;
        poolManager = _positionManager.poolManager();
        weth9 = INativeWrapper(address(_positionManager)).WETH9();
        feeSplitter = _feeSplitter;
        recipient = _recipient;
        liquidityBufferBps = _liquidityBufferBps;
    }

    /// @notice Receives the native ETH the PositionManager takes back when the increase does not consume
    ///         everything settled, and the native share the FeeSplitter force-sends on collect.
    receive() external payable {}

    /// @notice Collects `_tokenId`'s fees through the FeeSplitter and compounds the recipient's share
    ///         back into the position.
    /// @dev Permissionless: the destination of every wei is fixed by the FeeSplitter's immutable splits
    ///      and by this contract, so the caller chooses only when a compound happens.
    /// @param _tokenId The position to collect and compound
    /// @param _minCurrency0Amount The minimum currency0 the recipient must have attributed to `_tokenId`
    /// @param _minCurrency1Amount The minimum currency1 the recipient must have attributed to `_tokenId`
    function collectAndCompound(uint256 _tokenId, uint256 _minCurrency0Amount, uint256 _minCurrency1Amount)
        external
        nonReentrant
    {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId;
        feeSplitter.collectFees(tokenIds);

        _activeTokenIdPlusOne = _tokenId + 1;
        // Pays this contract, calls back into `onClaimed`, then asserts the liquidity grew enough.
        recipient.claim(_tokenId, _minCurrency0Amount, _minCurrency1Amount);
        delete _activeTokenIdPlusOne;

        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(_tokenId);
        _sweep(poolKey.currency0);
        _sweep(poolKey.currency1);
    }

    /// @inheritdoc IClaimExecutor
    /// @dev Settles the claimed amounts into the PositionManager and increases the position through the
    ///      FeeSplitter, which owns it. Whatever the increase does not consume is taken back here and
    ///      swept by `collectAndCompound`.
    function onClaimed(PoolKey memory poolKey, uint256 tokenId, uint256 currency0Received, uint256 currency1Received)
        external
    {
        if (msg.sender != address(recipient)) revert NotRecipient(msg.sender);
        uint256 activeTokenIdPlusOne = _activeTokenIdPlusOne;
        if (activeTokenIdPlusOne == 0) revert NoCompoundInProgress();
        if (activeTokenIdPlusOne - 1 != tokenId) revert TokenIdMismatch(activeTokenIdPlusOne - 1, tokenId);

        if (currency0Received != 0) {
            // The FeeSplitter's increase unwraps the PositionManager's WETH balance to settle native
            // currency0, so native proceeds have to arrive there wrapped.
            if (poolKey.currency0.isAddressZero()) {
                weth9.deposit{value: currency0Received}();
                Currency.wrap(address(weth9)).transfer(address(positionManager), currency0Received);
            } else {
                poolKey.currency0.transfer(address(positionManager), currency0Received);
            }
        }
        if (currency1Received != 0) poolKey.currency1.transfer(address(positionManager), currency1Received);

        uint128 liquidity = _liquidityFor(poolKey, tokenId, currency0Received, currency1Received);
        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);
        feeSplitter.increaseLiquidity(
            tokenId, liquidity, _toUint128Capped(currency0Received), _toUint128Capped(currency1Received), bytes("")
        );

        emit Compounded(
            tokenId,
            currency0Received,
            currency1Received,
            positionManager.getPositionLiquidity(tokenId) - liquidityBefore
        );
    }

    /// @notice Previews the liquidity a compound would request for the amounts already attributed to a
    ///         position, so a caller can check it against the recipient's `MIN_LIQUIDITY_INCREASE`
    ///         before spending gas. Ignores the fees the collect itself will realize.
    /// @param _tokenId The position to preview
    /// @return liquidity The liquidity the currently attributed amounts would buy
    function previewLiquidity(uint256 _tokenId) external view returns (uint128 liquidity) {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(_tokenId);
        (uint128 currency0Amount, uint128 currency1Amount) = recipient.amounts(_tokenId);
        return _liquidityFor(poolKey, _tokenId, currency0Amount, currency1Amount);
    }

    /// @notice The liquidity `_amount0`/`_amount1` buys in `_tokenId`'s range at the current price, less
    ///         the configured buffer.
    function _liquidityFor(PoolKey memory _poolKey, uint256 _tokenId, uint256 _amount0, uint256 _amount1)
        private
        view
        returns (uint128 liquidity)
    {
        (, PositionInfo info) = positionManager.getPoolAndPositionInfo(_tokenId);
        PoolId poolId = _poolKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint128 maxLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(info.tickLower()),
            TickMath.getSqrtPriceAtTick(info.tickUpper()),
            _amount0,
            _amount1
        );
        // `getLiquidityForAmounts` rounds down, but the pool rounds the amounts it charges for that
        // liquidity up; the buffer keeps the increase inside what was actually settled.
        return uint128(uint256(maxLiquidity) * (BPS_DENOMINATOR - liquidityBufferBps) / BPS_DENOMINATOR);
    }

    /// @notice Returns any standing balance to the FeeSplitter, where the next collect flushes it through
    ///         the splits rather than stranding it here.
    function _sweep(Currency _currency) private {
        uint256 balance = _currency.balanceOfSelf();
        if (balance != 0) _currency.transfer(address(feeSplitter), balance);
    }

    /// @notice Caps a settled amount to the uint128 the increase's slippage guard takes.
    function _toUint128Capped(uint256 _amount) private pure returns (uint128) {
        return _amount > type(uint128).max ? type(uint128).max : uint128(_amount);
    }
}
