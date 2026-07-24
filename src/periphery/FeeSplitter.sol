// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IFeeSplitter, FeeSplit} from "../interfaces/IFeeSplitter.sol";
import {IClaimablePositionRecipient} from "../interfaces/IClaimablePositionRecipient.sol";

/// @title FeeSplitter
/// @notice Immutable-configuration custodian of v4 native-ETH LP positions that permissionlessly
///         collects their fees and pushes independent fixed splits for native ETH and token fees.
/// @dev Positions sent to this contract are irrecoverable: no code path transfers or approves them out.
/// @custom:security-contact security@uniswap.org
contract FeeSplitter is IFeeSplitter, IERC721Receiver, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @notice The denominator for fee splits: each side's shares sum to this.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @inheritdoc IFeeSplitter
    IPositionManager public immutable override positionManager;

    FeeSplit[] internal _splits;

    /// @param _positionManager The canonical v4 PositionManager.
    /// @param splits_ The fee splits; each side's shares must sum to 10,000 bps.
    constructor(IPositionManager _positionManager, FeeSplit[] memory splits_) {
        positionManager = _positionManager;
        _validateAndStoreSplits(splits_);
    }

    /// @inheritdoc IFeeSplitter
    function getSplits() external view override returns (FeeSplit[] memory) {
        return _splits;
    }

    /// @inheritdoc IFeeSplitter
    function collectFees(uint256[] calldata tokenIds) external override nonReentrant {
        uint256 count = tokenIds.length;
        if (count == 0) revert NoTokenIds();
        for (uint256 i; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            (PoolKey memory poolKey, uint256 nativeAmount, uint256 tokenAmount) = _collect(tokenId);
            if (nativeAmount != 0 || tokenAmount != 0) {
                _distribute(tokenId, poolKey.currency1, nativeAmount, tokenAmount);
            }
        }
    }

    /// @inheritdoc IFeeSplitter
    /// @dev All fees MUST be collected first; reverts with UncollectedFees otherwise. The PositionManager
    ///      must already hold the WETH and token funding; excess is taken back to the caller.
    function increaseLiquidity(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) external override nonReentrant {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) {
            revert NotOwner(tokenId);
        }
        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);
        if (!poolKey.currency0.isAddressZero()) revert InvalidBaseCurrency(tokenId, poolKey.currency0);
        _requireNoPendingFees(tokenId, poolKey, info);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.UNWRAP),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](5);
        // Require the balance to already exist in PositionManager
        params[0] = abi.encode(ActionConstants.CONTRACT_BALANCE);
        params[1] = abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(tokenId, liquidity, amount0Max, amount1Max, hookData);
        params[4] = abi.encode(poolKey.currency0, poolKey.currency1, msg.sender);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    /// @notice Accepts positions safe-transferred through the PositionManager; any transfer data is
    ///         ignored. Other NFTs are rejected since they are not compatible with the PositionManager.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager(msg.sender);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Receives native ETH from the PositionManager take.
    receive() external payable {}

    /// @notice Reverts with UncollectedFees if the position has accrued fees since its last modification.
    function _requireNoPendingFees(uint256 tokenId, PoolKey memory poolKey, PositionInfo info) private view {
        IPoolManager poolManager = positionManager.poolManager();
        PoolId poolId = poolKey.toId();
        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = poolManager.getPositionInfo(
            poolId, address(positionManager), info.tickLower(), info.tickUpper(), bytes32(tokenId)
        );
        // A zero-liquidity position accrues nothing; its last modification realized everything.
        if (liquidity == 0) return;
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolId, info.tickLower(), info.tickUpper());
        if (feeGrowthInside0X128 != feeGrowthInside0LastX128 || feeGrowthInside1X128 != feeGrowthInside1LastX128) {
            revert UncollectedFees(tokenId);
        }
    }

    /// @notice Realizes one position's accrued fees into this contract's balances.
    /// @return poolKey The position's pool key; its currency0 is guaranteed to be native ETH.
    /// @return nativeAmount The full standing native balance to distribute.
    /// @return tokenAmount The full standing currency1 balance to distribute.
    function _collect(uint256 tokenId)
        private
        returns (PoolKey memory poolKey, uint256 nativeAmount, uint256 tokenAmount)
    {
        (poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        if (!poolKey.currency0.isAddressZero()) revert InvalidBaseCurrency(tokenId, poolKey.currency0);
        address token = Currency.unwrap(poolKey.currency1);

        // A zero-liquidity decrease realizes only the position's accrued fees.
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Distribute the full standing balances; donations are flushed through the split.
        nativeAmount = address(this).balance;
        tokenAmount = poolKey.currency1.balanceOfSelf();
        emit FeesCollected(tokenId, token, nativeAmount, tokenAmount);
    }

    /// @notice Pushes each split's shares of both sides in a single pass; rounding dust accrues to
    ///         later recipients.
    function _distribute(uint256 tokenId, Currency tokenCurrency, uint256 nativeAmount, uint256 tokenAmount) private {
        uint256 cumulativeNativeBps;
        uint256 cumulativeTokenBps;
        uint256 distributedNative;
        uint256 distributedToken;
        uint256 count = _splits.length;
        for (uint256 i; i < count; i++) {
            FeeSplit memory split = _splits[i];
            cumulativeNativeBps += split.nativeBps;
            cumulativeTokenBps += split.tokenBps;
            uint256 recipientNativeAmount =
                FullMath.mulDiv(nativeAmount, cumulativeNativeBps, BPS_DENOMINATOR) - distributedNative;
            uint256 recipientTokenAmount =
                FullMath.mulDiv(tokenAmount, cumulativeTokenBps, BPS_DENOMINATOR) - distributedToken;
            distributedNative += recipientNativeAmount;
            distributedToken += recipientTokenAmount;
            if (recipientNativeAmount == 0 && recipientTokenAmount == 0) continue;
            address recipient = split.recipient;
            if (recipientNativeAmount != 0) _transfer(CurrencyLibrary.ADDRESS_ZERO, recipient, recipientNativeAmount);
            if (recipientTokenAmount != 0) _transfer(tokenCurrency, recipient, recipientTokenAmount);
            if (split.useCallback && (recipientNativeAmount != 0 || recipientTokenAmount != 0)) {
                _tryCallback(tokenId, recipientNativeAmount, recipientTokenAmount, recipient);
            }
        }
    }

    /// @notice Native transfers are force-sent so a recipient can never block a collect.
    function _transfer(Currency currency, address recipient, uint256 amount) private {
        if (currency.isAddressZero()) {
            SafeTransferLib.forceSafeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(Currency.unwrap(currency), recipient, amount);
        }
        emit FeesForwarded(recipient, currency, amount);
    }

    /// @notice Callback failures are swallowed: a recipient can never brick the permissionless collect.
    function _tryCallback(uint256 tokenId, uint256 currency0Amount, uint256 currency1Amount, address recipient)
        private
    {
        try IClaimablePositionRecipient(recipient).onAmountsReceived(tokenId, currency0Amount, currency1Amount) {}
            catch {}
    }

    /// @notice Each side's shares must independently sum to the bps denominator; a split may carry a
    ///         single side but not neither.
    function _validateAndStoreSplits(FeeSplit[] memory splits_) private {
        uint256 count = splits_.length;
        if (count == 0) revert NoSplits();
        uint256 totalNativeBps;
        uint256 totalTokenBps;
        for (uint256 i; i < count; i++) {
            FeeSplit memory split = splits_[i];
            if (split.recipient == address(0) || split.recipient == address(this)) {
                revert InvalidRecipient(split.recipient);
            }
            if (split.nativeBps == 0 && split.tokenBps == 0) revert ZeroSplitBps(split.recipient);
            if (split.useCallback && split.recipient.code.length == 0) {
                revert CallbackRecipientNotContract(split.recipient);
            }
            for (uint256 j; j < i; j++) {
                if (splits_[j].recipient == split.recipient) revert DuplicateRecipient(split.recipient);
            }
            totalNativeBps += split.nativeBps;
            totalTokenBps += split.tokenBps;
            _splits.push(split);
        }
        if (totalNativeBps != BPS_DENOMINATOR) revert InvalidSplitTotal(totalNativeBps);
        if (totalTokenBps != BPS_DENOMINATOR) revert InvalidSplitTotal(totalTokenBps);
    }
}
