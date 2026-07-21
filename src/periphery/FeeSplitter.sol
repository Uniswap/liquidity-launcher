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
import {IUERC20} from "../interfaces/external/IUERC20.sol";

/// @notice A single fee allocation: `bps` of one currency side to `recipient`.
/// @param recipient The receiver of this share; may be the `CREATOR` sentinel.
/// @param bps The share in basis points. Each side's splits sum to 10,000.
struct FeeSplit {
    address recipient;
    uint16 bps;
}

/// @title FeeSplitter
/// @notice Singleton, immutable-configuration custodian of v4 LP positions that permissionlessly collects
///         their fees and pushes them to fixed recipients. Native ETH (currency0) and token (currency1)
///         fees are split independently. The `CREATOR` sentinel in a split resolves per pool to the
///         UERC20 `creator()` of that pool's token; unresolvable or undeliverable shares go to the
///         per-side fallback so a collect can never be bricked by a recipient.
/// @dev Positions sent to this contract are irrecoverable by design: there is no owner, no operator,
///      and no code path that transfers or approves a position out.
/// @custom:security-contact security@uniswap.org
contract FeeSplitter is IERC721Receiver, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;

    /// @notice The denominator for fee splits: each side's splits sum to this.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Sentinel recipient that resolves, per pool, to the UERC20 `creator()` of the pool's token.
    address public constant CREATOR = address(uint160(uint256(keccak256("FeeSplitter.CREATOR"))));

    /// @notice Gas allotted to the `creator()` staticcall so a non-compliant token cannot grief a collect.
    uint256 private constant CREATOR_CALL_GAS_LIMIT = 50_000;

    /// @notice Gas forwarded on native transfers to untrusted recipients (solady's no-grief stipend).
    uint256 private constant NATIVE_TRANSFER_GAS_STIPEND = 100_000;

    /// @notice The canonical v4 PositionManager holding the LP positions.
    IPositionManager public immutable positionManager;

    /// @notice Receives any native ETH share that cannot be delivered (unresolvable creator, failed send).
    address public immutable nativeFallback;

    /// @notice Receives any token share whose CREATOR recipient cannot be resolved.
    address public immutable tokenFallback;

    /// @dev True when any split on either side uses the CREATOR sentinel; skips resolution otherwise.
    bool private immutable hasCreatorSplit;

    /// @dev Written once in the constructor, never mutated.
    FeeSplit[] private _nativeSplits;
    FeeSplit[] private _tokenSplits;

    /// @notice Emitted once per collected position.
    /// @param tokenId The position collected.
    /// @param token The pool's currency1.
    /// @param nativeAmount The native ETH fees collected.
    /// @param tokenAmount The token fees collected.
    event FeesCollected(uint256 indexed tokenId, address indexed token, uint256 nativeAmount, uint256 tokenAmount);

    /// @notice Emitted for each nonzero amount pushed to a recipient.
    /// @param recipient The actual receiver (post CREATOR/fallback resolution).
    /// @param currency The currency sent; address(0) is native ETH.
    /// @param amount The amount sent.
    event FeesForwarded(address indexed recipient, Currency indexed currency, uint256 amount);

    /// @notice Thrown when a fallback address is zero, the CREATOR sentinel, or this contract.
    /// @param fallbackRecipient The invalid fallback.
    error InvalidFallback(address fallbackRecipient);

    /// @notice Thrown when a side is configured with no splits.
    error NoSplits();

    /// @notice Thrown when a split recipient is the zero address or this contract.
    /// @param recipient The invalid recipient.
    error InvalidRecipient(address recipient);

    /// @notice Thrown when a split has zero basis points.
    /// @param recipient The recipient of the empty split.
    error ZeroSplitBps(address recipient);

    /// @notice Thrown when a recipient appears twice on the same side.
    /// @param recipient The duplicated recipient.
    error DuplicateRecipient(address recipient);

    /// @notice Thrown when a side's splits do not sum to `BPS_DENOMINATOR`.
    /// @param totalBps The invalid total.
    error InvalidSplitTotal(uint256 totalBps);

    /// @notice Thrown when collectFees is called with no token IDs.
    error NoTokenIds();

    /// @notice Thrown when a position's currency0 is not native ETH.
    /// @param tokenId The offending position.
    /// @param currency0 The unexpected currency0.
    error InvalidBaseCurrency(uint256 tokenId, Currency currency0);

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
        if (_nativeFallback == address(0) || _nativeFallback == CREATOR || _nativeFallback == address(this)) {
            revert InvalidFallback(_nativeFallback);
        }
        if (_tokenFallback == address(0) || _tokenFallback == CREATOR || _tokenFallback == address(this)) {
            revert InvalidFallback(_tokenFallback);
        }

        positionManager = _positionManager;
        nativeFallback = _nativeFallback;
        tokenFallback = _tokenFallback;

        bool nativeHasCreator = _storeSplits(_nativeSplits, nativeSplits_);
        bool tokenHasCreator = _storeSplits(_tokenSplits, tokenSplits_);
        hasCreatorSplit = nativeHasCreator || tokenHasCreator;
    }

    /// @notice The configured native ETH (currency0) splits.
    function nativeSplits() external view returns (FeeSplit[] memory) {
        return _nativeSplits;
    }

    /// @notice The configured token (currency1) splits.
    function tokenSplits() external view returns (FeeSplit[] memory) {
        return _tokenSplits;
    }

    /// @notice Collects the accrued fees of each position and pushes the configured splits.
    /// @dev Permissionless. Each position is collected and distributed individually so fees are
    ///      attributed to that pool's token and creator. Positions must be native-ETH pairs and be
    ///      owned by (or approved to) this contract, otherwise the PositionManager reverts.
    /// @param tokenIds The position token IDs to collect.
    function collectFees(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length == 0) revert NoTokenIds();
        for (uint256 i; i < tokenIds.length; i++) {
            _collect(tokenIds[i]);
        }
    }

    /// @notice Accepts safe transfers of position NFTs.
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

        address creator;
        if (hasCreatorSplit) creator = _resolveCreator(token);

        if (nativeAmount != 0) {
            _distribute(_nativeSplits, CurrencyLibrary.ADDRESS_ZERO, nativeAmount, creator, nativeFallback);
        }
        if (tokenAmount != 0) {
            _distribute(_tokenSplits, poolKey.currency1, tokenAmount, creator, tokenFallback);
        }
    }

    /// @notice Pushes one side's splits of `amount`. Cumulative allocation assigns all rounding dust to
    ///         later recipients so the full amount is always forwarded.
    function _distribute(
        FeeSplit[] storage splits,
        Currency currency,
        uint256 amount,
        address creator,
        address fallbackRecipient
    ) private {
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
            if (recipient == CREATOR) recipient = creator == address(0) ? fallbackRecipient : creator;
            _transfer(currency, recipient, recipientAmount, fallbackRecipient);
        }
    }

    /// @notice Sends `amount` of `currency` to `recipient`; a failed native send is redirected to the
    ///         fallback so an unfunded or reverting recipient can never block a collect.
    function _transfer(Currency currency, address recipient, uint256 amount, address fallbackRecipient) private {
        if (currency.isAddressZero()) {
            if (!SafeTransferLib.trySafeTransferETH(recipient, amount, NATIVE_TRANSFER_GAS_STIPEND)) {
                // The fallback is trusted at deploy time to accept native transfers.
                SafeTransferLib.safeTransferETH(fallbackRecipient, amount);
                recipient = fallbackRecipient;
            }
        } else {
            SafeTransferLib.safeTransfer(Currency.unwrap(currency), recipient, amount);
        }
        emit FeesForwarded(recipient, currency, amount);
    }

    /// @notice Resolves a token's UERC20 creator; returns address(0) for any non-compliant token.
    /// @dev Bounded gas and manual decoding: a token that reverts, returns garbage, or return-bombs
    ///      must degrade to the fallback, never revert the collect.
    function _resolveCreator(address token) private view returns (address) {
        (bool success, bytes memory data) =
            token.staticcall{gas: CREATOR_CALL_GAS_LIMIT}(abi.encodeCall(IUERC20.creator, ()));
        if (!success || data.length != 32) return address(0);
        // Mask manually: abi.decode reverts on dirty upper bits, which a malicious token could exploit.
        return address(uint160(uint256(bytes32(data))));
    }

    /// @notice Validates and stores one side's splits; returns whether the side uses the CREATOR sentinel.
    function _storeSplits(FeeSplit[] storage store, FeeSplit[] memory splits) private returns (bool hasCreator) {
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
            if (split.recipient == CREATOR) hasCreator = true;
            totalBps += split.bps;
            store.push(split);
        }
        if (totalBps != BPS_DENOMINATOR) revert InvalidSplitTotal(totalBps);
    }
}
