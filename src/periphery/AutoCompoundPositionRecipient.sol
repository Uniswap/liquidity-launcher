// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {CurrencyAmounts} from "../types/PositionPlannerTypes.sol";
import {TimelockedPositionRecipient} from "./TimelockedPositionRecipient.sol";

/// @title AutoCompoundPositionRecipient
/// @notice Utility contract for holding v4 LP positions and permissionlessly compounding their accrued fees back
///         into the position
/// @dev Fees are only ever added in kind at the pool's current price — the contract never swaps, so compounding
///      creates no price impact and nothing to backrun. Budget that does not fit the current ratio is stored and
///      deployed by later compounds. Two guards bound what a price manipulator can extract from a compound:
///      each compound grows the position by at most `maxCompoundBps` of its current liquidity, and only one
///      compound can execute per block. A manipulate-compound-unwind bundle therefore extracts at most the
///      capped add's repricing loss, and repeating it requires holding the skewed price across blocks against
///      arbitrage while paying pool swap fees on the manipulation volume both ways (v4 flash accounting makes
///      the manipulation capital free, but not the swap fees, which remain the binding cost).
/// @custom:security-contact security@uniswap.org
contract AutoCompoundPositionRecipient is TimelockedPositionRecipient {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;
    using SafeCast for uint256;

    /// @notice Thrown when the currencies are not in v4 pool order
    /// @param currency0 The provided currency0
    /// @param currency1 The provided currency1
    error CurrenciesOutOfOrderOrEqual(address currency0, address currency1);
    /// @notice Thrown when the caller reward exceeds the maximum
    /// @param callerRewardBps The invalid caller reward
    error InvalidCallerRewardBps(uint16 callerRewardBps);
    /// @notice Thrown when the compound cap is zero or exceeds 100%
    /// @param maxCompoundBps The invalid compound cap
    error InvalidMaxCompoundBps(uint16 maxCompoundBps);
    /// @notice Thrown when a compound has already executed in the current block
    error AlreadyCompoundedThisBlock();
    /// @notice Thrown when a position's pool currencies do not match the configured currencies
    /// @param currency0 The position pool's currency0
    /// @param currency1 The position pool's currency1
    error CurrencyMismatch(Currency currency0, Currency currency1);
    /// @notice Thrown when the caller is not the operator
    /// @param caller The invalid caller
    error NotOperator(address caller);

    /// @notice Emitted when fees are compounded into a position
    /// @param caller The caller of the compound function
    /// @param tokenId The token ID of the compounded position
    /// @param liquidityAdded The liquidity added to the position
    /// @param collected0 The currency0 fees collected from the position
    /// @param collected1 The currency1 fees collected from the position
    event Compounded(
        address indexed caller, uint256 indexed tokenId, uint128 liquidityAdded, uint256 collected0, uint256 collected1
    );

    /// @notice Emitted when the operator sweeps a currency balance after the timelock
    /// @param currency The swept currency
    /// @param recipient The recipient of the swept balance
    /// @param amount The swept amount
    event Swept(Currency indexed currency, address indexed recipient, uint256 amount);

    /// @notice Denominator for bps values
    uint256 private constant MAX_BPS = 10_000;
    /// @notice The maximum configurable caller reward (10%)
    uint16 public constant MAX_CALLER_REWARD_BPS = 1_000;

    /// @notice The canonical v4 pool manager
    IPoolManager public immutable poolManager;
    /// @notice The pool currency with the lower address
    Currency public immutable currency0;
    /// @notice The pool currency with the higher address
    Currency public immutable currency1;
    /// @notice The share of collected fees paid to the compound caller, in bps
    uint16 public immutable callerRewardBps;
    /// @notice The maximum position liquidity growth per compound, in bps of the position's current liquidity
    uint16 public immutable maxCompoundBps;

    /// @notice The block number (blocknumberish) of the last compound
    uint256 public lastCompoundBlock;
    /// @notice Collected but not yet deployed budget per position
    /// @dev Budgets are tracked per token ID so a foreign position transferred to this contract can never deploy
    ///      another position's balance into its own pool
    mapping(uint256 tokenId => CurrencyAmounts) public rollover;

    constructor(
        Currency _currency0,
        Currency _currency1,
        address _operator,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        uint256 _timelockBlockNumber,
        uint16 _callerRewardBps,
        uint16 _maxCompoundBps
    ) TimelockedPositionRecipient(_positionManager, _operator, _timelockBlockNumber) {
        if (Currency.unwrap(_currency0) >= Currency.unwrap(_currency1)) {
            revert CurrenciesOutOfOrderOrEqual(Currency.unwrap(_currency0), Currency.unwrap(_currency1));
        }
        if (_callerRewardBps > MAX_CALLER_REWARD_BPS) revert InvalidCallerRewardBps(_callerRewardBps);
        if (_maxCompoundBps == 0 || _maxCompoundBps > MAX_BPS) revert InvalidMaxCompoundBps(_maxCompoundBps);
        poolManager = _poolManager;
        currency0 = _currency0;
        currency1 = _currency1;
        callerRewardBps = _callerRewardBps;
        maxCompoundBps = _maxCompoundBps;
    }

    /// @notice Collect any fees from the position and compound them back into the position
    /// @dev Callable by anyone, at most once per block across all positions held by this contract. The caller
    ///      receives `callerRewardBps` of the collected fees. The remainder joins the position's rollover budget,
    ///      from which liquidity is added at the pool's current price up to the per-compound cap.
    /// @param _tokenId The token ID of the position
    /// @return liquidityAdded The liquidity added to the position
    function compound(uint256 _tokenId) external nonReentrant returns (uint128 liquidityAdded) {
        uint256 blockNumber = _getBlockNumberish();
        if (blockNumber == lastCompoundBlock) revert AlreadyCompoundedThisBlock();
        lastCompoundBlock = blockNumber;

        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(_tokenId);
        if (!(poolKey.currency0 == currency0 && poolKey.currency1 == currency1)) {
            revert CurrencyMismatch(poolKey.currency0, poolKey.currency1);
        }

        (uint256 collected0, uint256 collected1) = _collectFees(_tokenId);

        // The reward is a share of freshly collected fees only, never of held rollover budgets, so repeated
        // compounding can never pay out more than callerRewardBps of the fees the position actually earned
        uint256 reward0 = collected0 * callerRewardBps / MAX_BPS;
        uint256 reward1 = collected1 * callerRewardBps / MAX_BPS;

        CurrencyAmounts memory budget = rollover[_tokenId];
        budget.amount0 += collected0 - reward0;
        budget.amount1 += collected1 - reward1;

        uint256 spent0;
        uint256 spent1;
        (liquidityAdded, spent0, spent1) = _increaseLiquidity(_tokenId, poolKey, info, budget);

        rollover[_tokenId] = CurrencyAmounts({amount0: budget.amount0 - spent0, amount1: budget.amount1 - spent1});

        emit Compounded(msg.sender, _tokenId, liquidityAdded, collected0, collected1);

        if (reward0 > 0) currency0.transfer(msg.sender, reward0);
        if (reward1 > 0) currency1.transfer(msg.sender, reward1);
    }

    /// @notice Transfer this contract's full balance of a currency to a recipient
    /// @dev Only callable by the operator after the timelock. Intended for decommissioning: compounding a
    ///      position whose rollover budget was swept will revert until the balance is restored.
    /// @param _currency The currency to sweep
    /// @param _recipient The recipient of the swept balance
    function sweep(Currency _currency, address _recipient) external nonReentrant {
        if (_getBlockNumberish() < timelockBlockNumber) revert Timelocked();
        if (msg.sender != operator) revert NotOperator(msg.sender);

        uint256 amount = _currency.balanceOfSelf();
        _currency.transfer(_recipient, amount);

        emit Swept(_currency, _recipient, amount);
    }

    /// @notice Collects the position's accrued fees into this contract
    /// @return collected0 The amount of currency0 collected
    /// @return collected1 The amount of currency1 collected
    function _collectFees(uint256 _tokenId) private returns (uint256 collected0, uint256 collected1) {
        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        // Call DECREASE_LIQUIDITY with a liquidity of 0 to collect fees
        params[0] = abi.encode(_tokenId, 0, 0, 0, bytes(""));
        // Call TAKE_PAIR to send the collected fees to this contract
        params[1] = abi.encode(currency0, currency1, address(this));

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        collected0 = currency0.balanceOfSelf() - balance0Before;
        collected1 = currency1.balanceOfSelf() - balance1Before;
    }

    /// @notice Adds as much of the budget as the current price ratio and per-compound cap allow to the position
    /// @return liquidity The liquidity added
    /// @return spent0 The amount of currency0 consumed from the budget
    /// @return spent1 The amount of currency1 consumed from the budget
    function _increaseLiquidity(uint256 _tokenId, PoolKey memory _poolKey, PositionInfo _info, CurrencyAmounts memory _budget)
        private
        returns (uint128 liquidity, uint256 spent0, uint256 spent1)
    {
        uint256 amount0;
        uint256 amount1;
        (liquidity, amount0, amount1) = _quoteAdd(_tokenId, _poolKey, _info, _budget);
        if (liquidity == 0) return (0, 0, 0);

        uint256 balance0Before = currency0.balanceOfSelf();
        uint256 balance1Before = currency1.balanceOfSelf();

        _executeIncrease(_tokenId, liquidity, amount0, amount1);

        spent0 = balance0Before - currency0.balanceOfSelf();
        spent1 = balance1Before - currency1.balanceOfSelf();
    }

    /// @notice Quotes the capped liquidity addable from the budget and the exact amounts owed for it
    function _quoteAdd(uint256 _tokenId, PoolKey memory _poolKey, PositionInfo _info, CurrencyAmounts memory _budget)
        private
        view
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_poolKey.toId());
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_info.tickLower());
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_info.tickUpper());

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, _budget.amount0, _budget.amount1
        );

        // Cap the add so a single compound at a manipulated price bounds the extractable value. The product of
        // two values below type(uint128).max cannot overflow uint256 and the cap keeps the result in uint128.
        uint256 maxLiquidity = uint256(positionManager.getPositionLiquidity(_tokenId)) * maxCompoundBps / MAX_BPS;
        if (liquidity > maxLiquidity) liquidity = uint128(maxLiquidity);
        if (liquidity == 0) return (0, 0, 0);

        // Quote the exact amounts owed for the liquidity with v4 core rounding so the transferred balances always
        // cover the PoolManager's required input deltas (and, per PositionPlanner, never exceed the budget)
        (amount0, amount1) = _getAmountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);
    }

    /// @notice Transfers the owed amounts to the PositionManager and executes the increase
    function _executeIncrease(uint256 _tokenId, uint128 _liquidity, uint256 _amount0, uint256 _amount1) private {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(_tokenId, _liquidity, _amount0.toUint128(), _amount1.toUint128(), bytes(""));
        // Settle both currencies from the balances transferred to the PositionManager below
        params[1] = abi.encode(currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(currency1, ActionConstants.CONTRACT_BALANCE, false);
        // Call TAKE_PAIR to return any unconsumed dust to this contract
        params[3] = abi.encode(currency0, currency1, address(this));
        bytes memory unlockData = abi.encode(actions, params);

        if (currency0.isAddressZero()) {
            if (_amount1 > 0) currency1.transfer(address(positionManager), _amount1);
            positionManager.modifyLiquidities{value: _amount0}(unlockData, block.timestamp);
        } else {
            if (_amount0 > 0) currency0.transfer(address(positionManager), _amount0);
            if (_amount1 > 0) currency1.transfer(address(positionManager), _amount1);
            positionManager.modifyLiquidities(unlockData, block.timestamp);
        }
    }

    /// @notice Quotes token amounts for a liquidity position using v4 core mint math
    /// @dev Mirrors PositionPlanner._getAmountsForLiquidity: roundUp=true so the amounts cover the PoolManager's
    ///      required input deltas
    function _getAmountsForLiquidity(
        uint160 _sqrtPriceX96,
        uint160 _sqrtPriceLowerX96,
        uint160 _sqrtPriceUpperX96,
        uint128 _liquidity
    ) private pure returns (uint256, uint256) {
        if (_sqrtPriceX96 <= _sqrtPriceLowerX96) {
            return (SqrtPriceMath.getAmount0Delta(_sqrtPriceLowerX96, _sqrtPriceUpperX96, _liquidity, true), 0);
        } else if (_sqrtPriceX96 < _sqrtPriceUpperX96) {
            return (
                SqrtPriceMath.getAmount0Delta(_sqrtPriceX96, _sqrtPriceUpperX96, _liquidity, true),
                SqrtPriceMath.getAmount1Delta(_sqrtPriceLowerX96, _sqrtPriceX96, _liquidity, true)
            );
        } else {
            return (0, SqrtPriceMath.getAmount1Delta(_sqrtPriceLowerX96, _sqrtPriceUpperX96, _liquidity, true));
        }
    }
}
