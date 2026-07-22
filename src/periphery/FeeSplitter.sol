// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IFeeSplitter, FeeSplit, FEE_BENEFICIARY_SENTINEL} from "../interfaces/IFeeSplitter.sol";

/// @title FeeSplitter
/// @notice Singleton, immutable-configuration custodian of v4 LP positions that permissionlessly collects
///         their fees and pushes them to fixed recipients. Native ETH (currency0) and token (currency1)
///         fees are split independently. The fee-beneficiary sentinel in a split resolves per position
///         to the beneficiary registered at deposit; unregistered or undeliverable shares go to the
///         per-side fallback so a collect can never be bricked by a recipient.
/// @dev Positions sent to this contract are irrecoverable by design: there is no owner, no operator,
///      and no code path that transfers or approves a position out.
/// @custom:security-contact security@uniswap.org
contract FeeSplitter is IFeeSplitter, IERC721Receiver, ERC721, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

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
    /// @param _tokenFallback Receiver for token shares whose beneficiary cannot be resolved.
    /// @param nativeSplits_ The native ETH (currency0) fee splits; must sum to 10,000 bps.
    /// @param tokenSplits_ The token (currency1) fee splits; must sum to 10,000 bps.
    constructor(
        IPositionManager _positionManager,
        address _nativeFallback,
        address _tokenFallback,
        FeeSplit[] memory nativeSplits_,
        FeeSplit[] memory tokenSplits_
    ) {
        if (!_isValidFeeRecipient(_nativeFallback)) revert InvalidFallback(_nativeFallback);
        if (!_isValidFeeRecipient(_tokenFallback)) revert InvalidFallback(_tokenFallback);

        positionManager = _positionManager;
        nativeFallback = _nativeFallback;
        tokenFallback = _tokenFallback;

        _validateAndStoreSplits(nativeSplits, nativeSplits_);
        _validateAndStoreSplits(tokenSplits, tokenSplits_);
    }

    /// @inheritdoc ERC721
    function name() public pure override returns (string memory) {
        return "FeeSplitter Beneficiary";
    }

    /// @inheritdoc ERC721
    function symbol() public pure override returns (string memory) {
        return "FSB";
    }

    /// @inheritdoc ERC721
    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
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
            _collect(tokenIds[i], 0);
        }
    }

    /// @inheritdoc IFeeSplitter
    function increasePosition(uint256 tokenId, uint256 tokenAmount) external payable override nonReentrant {
        // Collect and distribute pending fees first: a v4 liquidity increase credits accrued fees
        // toward the payment, so increasing without collecting would silently convert everyone's
        // undistributed shares into locked liquidity. msg.value is the caller's funding, not fees,
        // and is excluded from the distribution.
        (PoolKey memory poolKey, PositionInfo info) = _collect(tokenId, msg.value);
        address token = Currency.unwrap(poolKey.currency1);
        if (tokenAmount != 0) {
            SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), tokenAmount);
            // The collect above zeroed the token balance, so the pull must deliver exactly
            // tokenAmount — fee-on-transfer tokens are unsupported (as everywhere in this system)
            // and would otherwise revert opaquely when the nominal amount is forwarded below.
            uint256 received = poolKey.currency1.balanceOfSelf();
            if (received != tokenAmount) revert TokenAmountMismatch(received, tokenAmount);
        }

        (uint160 sqrtPriceX96,,,) = positionManager.poolManager().getSlot0(poolKey.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(info.tickLower()),
            TickMath.getSqrtPriceAtTick(info.tickUpper()),
            msg.value,
            tokenAmount
        );
        if (liquidity == 0) revert ZeroLiquidity();

        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            tokenId, liquidity, SafeCastLib.toUint128(msg.value), SafeCastLib.toUint128(tokenAmount), bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false);
        // Unused remainder returns here and is flushed through the split by a future collect.
        params[3] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        SafeTransferLib.safeTransfer(token, address(positionManager), tokenAmount);
        positionManager.modifyLiquidities{value: msg.value}(abi.encode(actions, params), block.timestamp);

        emit PositionIncreased(tokenId, liquidity, msg.value, tokenAmount);
    }

    /// @notice Accepts positions safe-transferred through the PositionManager and mints this
    ///         contract's beneficiary NFT (same tokenId as the position) to the address carried in
    ///         the transfer data, when present.
    /// @dev Only PositionManager callbacks are accepted, so a registration verifiably comes from the
    ///      position's owner; the mint cannot repeat since positions never leave the splitter. The
    ///      NFT's current holder receives the sentinel fee share and may transfer it freely — no
    ///      restriction is placed on transfers, so sending it to an address that cannot benefit
    ///      (this contract, the sentinel) only misroutes that holder's own future share. Adding fee
    ///      beneficiaries is NOT supported for positions minted or sent to this contract without
    ///      triggering this callback. Other NFTs are rejected: they would be irrecoverably stuck,
    ///      since collectFees only interacts with the PositionManager.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager(msg.sender);
        if (data.length != 0) {
            address beneficiary = abi.decode(data, (address));
            if (!_isValidFeeRecipient(beneficiary)) revert InvalidRecipient(beneficiary);
            _mint(beneficiary, tokenId);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Receives native ETH from the PositionManager take.
    receive() external payable {}

    /// @notice Collects one position's fees to this contract and distributes both sides.
    /// @param reservedNative Native balance that is NOT fees (a caller's increase funding) and must
    ///        be excluded from the distribution.
    function _collect(uint256 tokenId, uint256 reservedNative)
        private
        returns (PoolKey memory poolKey, PositionInfo info)
    {
        (poolKey, info) = positionManager.getPoolAndPositionInfo(tokenId);
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
        uint256 nativeAmount = address(this).balance - reservedNative;
        uint256 tokenAmount = poolKey.currency1.balanceOfSelf();
        emit FeesCollected(tokenId, token, nativeAmount, tokenAmount);

        // Resolution order: the current beneficiary NFT holder, else the per-side fallback. A
        // resolved beneficiary that cannot receive a native send also falls back (see _transfer).
        // _ownerOf is the non-reverting read: zero when no beneficiary was ever minted.
        address beneficiary = _ownerOf(tokenId);
        if (nativeAmount != 0) {
            _distribute(
                nativeSplits,
                CurrencyLibrary.ADDRESS_ZERO,
                nativeAmount,
                beneficiary == address(0) ? nativeFallback : beneficiary
            );
        }
        if (tokenAmount != 0) {
            _distribute(
                tokenSplits, poolKey.currency1, tokenAmount, beneficiary == address(0) ? tokenFallback : beneficiary
            );
        }
    }

    /// @notice Pushes one side's splits of `amount`. Cumulative allocation assigns all rounding dust to
    ///         later recipients so the full amount is always forwarded.
    function _distribute(FeeSplit[] storage splits, Currency currency, uint256 amount, address beneficiary) private {
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
            if (recipient == FEE_BENEFICIARY_SENTINEL) recipient = beneficiary;
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

    /// @notice True when `recipient` can meaningfully receive a fee share: zero, this contract, and
    ///         the sentinel would burn or recycle the share instead of paying anyone.
    function _isValidFeeRecipient(address recipient) private view returns (bool) {
        return recipient != address(0) && recipient != address(this) && recipient != FEE_BENEFICIARY_SENTINEL;
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
