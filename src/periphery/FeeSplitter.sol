// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IFeeSplitter, FeeSplit, FEE_BENEFICIARY_SENTINEL} from "../interfaces/IFeeSplitter.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ILPFeesPositionRecipient} from "../interfaces/ILPFeesPositionRecipient.sol";

/// @title FeeSplitter
/// @notice Singleton, immutable-configuration custodian of v4 LP positions that permissionlessly collects
///         their fees and pushes them to fixed recipients. Native ETH (currency0) and token (currency1)
///         fees are split independently. The fee-beneficiary sentinel in a split resolves per position
///         to the beneficiary registered at deposit; unregistered shares go to the per-side fallback.
///         Native shares are force-sent, so a collect can never be blocked by a recipient.
/// @dev Positions sent to this contract are irrecoverable by design: there is no owner, no operator,
///      and no code path that transfers or approves a position out.
/// @custom:security-contact security@uniswap.org
contract FeeSplitter is IFeeSplitter, IERC721Receiver, ERC721, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;

    /// @notice The denominator for fee splits: each side's splits sum to this.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @inheritdoc IFeeSplitter
    IPositionManager public immutable override positionManager;

    /// @inheritdoc IFeeSplitter
    address public immutable override nativeFallback;

    /// @inheritdoc IFeeSplitter
    address public immutable override tokenFallback;

    /// @inheritdoc IFeeSplitter
    FeeSplit[] public override splits;

    /// @param _positionManager The canonical v4 PositionManager.
    /// @param _nativeFallback Receiver of the sentinel's native ETH share when no beneficiary is registered.
    /// @param _tokenFallback Receiver of the sentinel's token share when no beneficiary is registered.
    /// @param splits_ The fee splits; each side's shares (nativeBps, tokenBps) must sum to 10,000 bps.
    constructor(
        IPositionManager _positionManager,
        address _nativeFallback,
        address _tokenFallback,
        FeeSplit[] memory splits_
    ) {
        if (!_isValidFeeRecipient(_nativeFallback)) revert InvalidFallback(_nativeFallback);
        if (!_isValidFeeRecipient(_tokenFallback)) revert InvalidFallback(_tokenFallback);

        positionManager = _positionManager;
        nativeFallback = _nativeFallback;
        tokenFallback = _tokenFallback;

        _validateAndStoreSplits(splits_);
    }

    /// @inheritdoc IFeeSplitter
    function getSplits() external view override returns (FeeSplit[] memory) {
        return splits;
    }

    /// @inheritdoc IFeeSplitter
    function collectFees(uint256[] calldata tokenIds) external override nonReentrant {
        uint256 count = tokenIds.length;
        if (count == 0) revert NoTokenIds();
        for (uint256 i; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            (PoolKey memory poolKey, uint256 nativeAmount, uint256 tokenAmount) = _collect(tokenId);
            if (nativeAmount != 0 || tokenAmount != 0) {
                _distribute(tokenId, poolKey.currency1, nativeAmount, tokenAmount, _ownerOf(tokenId));
            }
        }
    }

    /// @inheritdoc IFeeSplitter
    /// @notice Permissionlessly increase the liquidity of a position held in the FeeSplitter
    /// @dev The PositionManager must already hold a WETH and token balance, and any excess will be taken back to the caller
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
        // Collect any outstanding fees on the existing liquidity first
        (PoolKey memory poolKey, uint256 nativeAmount, uint256 tokenAmount) = _collect(tokenId);

        {
            // Increase liquidity
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

        // Distribute fees to all configured recipients
        if (nativeAmount != 0 || tokenAmount != 0) {
            _distribute(tokenId, poolKey.currency1, nativeAmount, tokenAmount, _ownerOf(tokenId));
        }
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

        // Distribute the full standing balances: every collect ends at zero, so outside the
        // (pointless) donation case these equal the fees just collected — and donations are
        // simply flushed through the split instead of being stuck here forever.
        nativeAmount = address(this).balance;
        tokenAmount = poolKey.currency1.balanceOfSelf();
        emit FeesCollected(tokenId, token, nativeAmount, tokenAmount);
    }

    /// @notice Pushes every split's shares of both sides in a single pass. Per-side cumulative
    ///         allocation assigns all rounding dust to later recipients so the full amounts are
    ///         always forwarded.
    /// @dev The sentinel resolves to the beneficiary registered at deposit. Unregistered positions
    ///      send each side of the sentinel share to that side's fallback, with no callback.
    function _distribute(
        uint256 tokenId,
        Currency tokenCurrency,
        uint256 nativeAmount,
        uint256 tokenAmount,
        address beneficiary
    ) private {
        uint256 cumulativeNativeBps;
        uint256 cumulativeTokenBps;
        uint256 distributedNative;
        uint256 distributedToken;
        uint256 count = splits.length;
        for (uint256 i; i < count; i++) {
            FeeSplit memory split = splits[i];
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
            if (recipient == FEE_BENEFICIARY_SENTINEL) {
                if (beneficiary == address(0)) {
                    if (recipientNativeAmount != 0) {
                        _transfer(CurrencyLibrary.ADDRESS_ZERO, nativeFallback, recipientNativeAmount);
                    }
                    if (recipientTokenAmount != 0) _transfer(tokenCurrency, tokenFallback, recipientTokenAmount);
                    continue;
                }
                recipient = beneficiary;
            }

            if (recipientNativeAmount != 0) _transfer(CurrencyLibrary.ADDRESS_ZERO, recipient, recipientNativeAmount);
            if (recipientTokenAmount != 0) _transfer(tokenCurrency, recipient, recipientTokenAmount);

            if (split.useCallback && (recipientNativeAmount != 0 || recipientTokenAmount != 0)) {
                _tryCallback(tokenId, recipientNativeAmount, recipientTokenAmount, recipient);
            }
        }
    }

    /// @notice Sends `amount` of `currency` to `recipient`; Native transfers are force sent.
    function _transfer(Currency currency, address recipient, uint256 amount) private {
        if (currency.isAddressZero()) {
            SafeTransferLib.forceSafeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(Currency.unwrap(currency), recipient, amount);
        }
        emit FeesForwarded(recipient, currency, amount);
    }

    /// @notice Tries to call the onFeesReceived callback on the recipient
    /// @dev Does NOT revert if the callback fails
    function _tryCallback(uint256 tokenId, uint256 currency0Amount, uint256 currency1Amount, address recipient)
        private
    {
        try ILPFeesPositionRecipient(recipient).onFeesReceived(tokenId, currency0Amount, currency1Amount) {} catch {}
    }

    /// @notice True when `recipient` can meaningfully receive a fee share: zero, this contract, and
    ///         the sentinel would burn or recycle the share instead of paying anyone.
    function _isValidFeeRecipient(address recipient) private view returns (bool) {
        return recipient != address(0) && recipient != address(this) && recipient != FEE_BENEFICIARY_SENTINEL;
    }

    /// @notice Validates and stores the splits: each side's shares must independently sum to the
    ///         bps denominator; a split may carry a single side but not neither.
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
            for (uint256 j; j < i; j++) {
                if (splits_[j].recipient == split.recipient) revert DuplicateRecipient(split.recipient);
            }
            totalNativeBps += split.nativeBps;
            totalTokenBps += split.tokenBps;
            splits.push(split);
        }
        if (totalNativeBps != BPS_DENOMINATOR) revert InvalidSplitTotal(totalNativeBps);
        if (totalTokenBps != BPS_DENOMINATOR) revert InvalidSplitTotal(totalTokenBps);
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
}
