// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IFeeSplitter, FeeSplit, CREATOR_SENTINEL} from "../interfaces/IFeeSplitter.sol";
import {IUERC20} from "../interfaces/external/IUERC20.sol";

/// @title FeeSplitter
/// @notice Singleton, immutable-configuration custodian of v4 LP positions that permissionlessly collects
///         their fees and pushes them to fixed recipients. Native ETH (currency0) and token (currency1)
///         fees are split independently. The `CREATOR` sentinel in a split resolves per pool to the
///         UERC20 `creator()` of that pool's token; unresolvable or undeliverable shares go to the
///         per-side fallback so a collect can never be bricked by a recipient.
/// @dev Positions sent to this contract are irrecoverable by design: there is no owner, no operator,
///      and no code path that transfers or approves a position out.
/// @custom:security-contact security@uniswap.org
contract FeeSplitter is IFeeSplitter, IERC721Receiver, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;

    /// @notice The denominator for fee splits: each side's splits sum to this.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Gas forwarded on native transfers to untrusted recipients (solady's no-grief stipend).
    uint256 private constant NATIVE_TRANSFER_GAS_STIPEND = 100_000;

    /// @inheritdoc IFeeSplitter
    IPositionManager public immutable override positionManager;

    /// @inheritdoc IFeeSplitter
    address public immutable override nativeFallback;

    /// @inheritdoc IFeeSplitter
    address public immutable override tokenFallback;

    /// @inheritdoc IFeeSplitter
    FeeSplit[] public override nativeSplits;
    /// @inheritdoc IFeeSplitter
    FeeSplit[] public override tokenSplits;

    /// @param _positionManager The canonical v4 PositionManager.
    /// @param _nativeFallback Trusted receiver for undeliverable native ETH shares; must accept plain sends.
    /// @param _tokenFallback Receiver for token shares whose CREATOR cannot be resolved.
    /// @param nativeSplits_ The native ETH (currency0) fee splits; must sum to 10,000 bps.
    /// @param tokenSplits_ The token (currency1) fee splits; must sum to 10,000 bps.
    constructor(
        IPositionManager _positionManager,
        address _nativeFallback,
        address _tokenFallback,
        FeeSplit[] memory nativeSplits_,
        FeeSplit[] memory tokenSplits_
    ) {
        if (_nativeFallback == address(0) || _nativeFallback == CREATOR_SENTINEL || _nativeFallback == address(this)) {
            revert InvalidFallback(_nativeFallback);
        }
        if (_tokenFallback == address(0) || _tokenFallback == CREATOR_SENTINEL || _tokenFallback == address(this)) {
            revert InvalidFallback(_tokenFallback);
        }

        positionManager = _positionManager;
        nativeFallback = _nativeFallback;
        tokenFallback = _tokenFallback;

        _validateAndStoreSplits(nativeSplits, nativeSplits_);
        _validateAndStoreSplits(tokenSplits, tokenSplits_);
    }

    /// @inheritdoc IFeeSplitter
    function getNativeSplits() external view override returns (FeeSplit[] memory) {
        return nativeSplits;
    }

    /// @inheritdoc IFeeSplitter
    function getTokenSplits() external view override returns (FeeSplit[] memory) {
        return tokenSplits;
    }

    /// @inheritdoc IFeeSplitter
    function collectFees(uint256[] calldata tokenIds) external override nonReentrant {
        uint256 count = tokenIds.length;
        if (count == 0) revert NoTokenIds();
        for (uint256 i; i < count; i++) {
            _collect(tokenIds[i]);
        }
    }

    /// @notice Accepts safe transfers of position NFTs, so safeTransferFrom-based flows can move
    ///         positions into the splitter (solmate's safeTransferFrom reverts on contract receivers
    ///         that do not return this selector).
    /// @dev Cannot gate inbound positions: the PositionManager mints with solmate `_mint`, which
    ///      performs no receiver callback, and plain `transferFrom` does not either. Foreign NFTs
    ///      sent here are inert — `collectFees` only interacts with the immutable PositionManager.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Receives native ETH from the PositionManager take.
    receive() external payable {}

    /// @notice Collects one position's fees to this contract and distributes both sides.
    function _collect(uint256 tokenId) private {
        (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
        if (!poolKey.currency0.isAddressZero()) revert InvalidBaseCurrency(tokenId, poolKey.currency0);
        address token = Currency.unwrap(poolKey.currency1);

        // A zero-liquidity decrease realizes only the position's accrued fees.
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Distribute the full standing balances: every collect ends at zero, so outside the
        // (pointless) donation case these equal the fees just collected — and donations are
        // simply flushed through the split instead of being stuck here forever.
        uint256 nativeAmount = address(this).balance;
        uint256 tokenAmount = poolKey.currency1.balanceOfSelf();
        emit FeesCollected(tokenId, token, nativeAmount, tokenAmount);

        // Resolve the pool's creator once; an unresolvable creator degrades to the per-side fallback.
        address creator = _resolveCreator(token);
        if (nativeAmount != 0) {
            _distribute(
                nativeSplits,
                CurrencyLibrary.ADDRESS_ZERO,
                nativeAmount,
                creator == address(0) ? nativeFallback : creator
            );
        }
        if (tokenAmount != 0) {
            _distribute(tokenSplits, poolKey.currency1, tokenAmount, creator == address(0) ? tokenFallback : creator);
        }
    }

    /// @notice Pushes one side's splits of `amount`. Cumulative allocation assigns all rounding dust to
    ///         later recipients so the full amount is always forwarded.
    function _distribute(FeeSplit[] storage splits, Currency currency, uint256 amount, address creatorRecipient)
        private
    {
        uint256 cumulativeBps;
        uint256 distributed;
        uint256 count = splits.length;
        for (uint256 i; i < count; i++) {
            FeeSplit memory split = splits[i];
            cumulativeBps += split.bps;
            uint256 cumulativeAmount = FullMath.mulDiv(amount, cumulativeBps, BPS_DENOMINATOR);
            uint256 recipientAmount = cumulativeAmount - distributed;
            distributed = cumulativeAmount;
            if (recipientAmount == 0) continue;

            address recipient = split.recipient;
            if (recipient == CREATOR_SENTINEL) recipient = creatorRecipient;
            _transfer(currency, recipient, recipientAmount);
        }
    }

    /// @notice Sends `amount` of `currency` to `recipient`; a failed native send is redirected to the
    ///         native fallback so an unfunded or reverting recipient can never block a collect. Token
    ///         transfers have no receive hook to fail on and revert only for non-standard tokens.
    function _transfer(Currency currency, address recipient, uint256 amount) private {
        if (currency.isAddressZero()) {
            if (!SafeTransferLib.trySafeTransferETH(recipient, amount, NATIVE_TRANSFER_GAS_STIPEND)) {
                // The fallback is trusted at deploy time to accept native transfers.
                SafeTransferLib.safeTransferETH(nativeFallback, amount);
                recipient = nativeFallback;
            }
        } else {
            SafeTransferLib.safeTransfer(Currency.unwrap(currency), recipient, amount);
        }
        emit FeesForwarded(recipient, currency, amount);
    }

    /// @notice Resolves a token's UERC20 creator; returns address(0) for any non-compliant token.
    /// @dev Manual decoding: a token that reverts or returns garbage must degrade to the fallback,
    ///      never revert the collect.
    function _resolveCreator(address token) private view returns (address) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IUERC20.creator, ()));
        if (!success || data.length != 32) return address(0);
        // Mask manually: abi.decode reverts on dirty upper bits, which a malicious token could exploit.
        return address(uint160(uint256(bytes32(data))));
    }

    /// @notice Validates and stores one side's splits.
    function _validateAndStoreSplits(FeeSplit[] storage store, FeeSplit[] memory splits) private {
        uint256 count = splits.length;
        if (count == 0) revert NoSplits();

        uint256 totalBps;
        for (uint256 i; i < count; i++) {
            FeeSplit memory split = splits[i];
            if (split.recipient == address(0) || split.recipient == address(this)) {
                revert InvalidRecipient(split.recipient);
            }
            if (split.bps == 0) revert ZeroSplitBps(split.recipient);
            for (uint256 j; j < i; j++) {
                if (splits[j].recipient == split.recipient) revert DuplicateRecipient(split.recipient);
            }
            totalBps += split.bps;
            store.push(split);
        }
        if (totalBps != BPS_DENOMINATOR) revert InvalidSplitTotal(totalBps);
    }
}
