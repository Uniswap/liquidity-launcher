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
import {IFeeSplitter, FeeSplit, FEE_BENEFICIARY_SENTINEL} from "../interfaces/IFeeSplitter.sol";
import {IUERC20} from "../interfaces/external/IUERC20.sol";

/// @title FeeSplitter
/// @notice Singleton, immutable-configuration custodian of v4 LP positions that permissionlessly collects
///         their fees and pushes them to fixed recipients. Native ETH (currency0) and token (currency1)
///         fees are split independently. The fee-beneficiary sentinel in a split resolves per position
///         to its registered beneficiary, falling back to the UERC20 `creator()` of the pool's token;
///         unresolvable or undeliverable shares go to the
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

    /// @inheritdoc IFeeSplitter
    mapping(uint256 tokenId => address beneficiary) public override feeBeneficiary;

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
        if (
            _nativeFallback == address(0) || _nativeFallback == FEE_BENEFICIARY_SENTINEL
                || _nativeFallback == address(this)
        ) {
            revert InvalidFallback(_nativeFallback);
        }
        if (
            _tokenFallback == address(0) || _tokenFallback == FEE_BENEFICIARY_SENTINEL
                || _tokenFallback == address(this)
        ) {
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

    /// @notice Accepts positions safe-transferred through the PositionManager and registers the
    ///         transfer data, when present, as the position's fee beneficiary.
    /// @dev Only PositionManager callbacks are accepted, so a registration verifiably comes from the
    ///      position's owner, and it never changes: positions cannot leave the splitter. Adding fee
    ///      beneficiaries is NOT supported for positions minted or sent to this contract without
    ///      triggering this callback. Other NFTs are rejected: they would be irrecoverably stuck,
    ///      since collectFees only interacts with the PositionManager.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager(msg.sender);
        if (data.length != 0) {
            address beneficiary = abi.decode(data, (address));
            // Mirrors the constructor's recipient hygiene: zero, this contract, and the sentinel
            // would burn or recycle the share instead of paying a beneficiary.
            if (beneficiary == address(0) || beneficiary == address(this) || beneficiary == FEE_BENEFICIARY_SENTINEL) {
                revert InvalidRecipient(beneficiary);
            }
            feeBeneficiary[tokenId] = beneficiary;
            emit FeeBeneficiarySet(tokenId, beneficiary);
        }
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

        // Resolution order: the beneficiary registered at deposit, else the token's own creator(),
        // else the per-side fallback. A resolved beneficiary that cannot receive a native send is
        // redirected to the native fallback in _transfer.
        address beneficiary = feeBeneficiary[tokenId];
        if (beneficiary == address(0)) beneficiary = _resolveTokenCreator(token);
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

    /// @notice Resolves a token's UERC20 creator as the default beneficiary; returns address(0) for
    ///         any non-compliant token.
    /// @dev Manual decoding: a token that reverts or returns garbage must degrade to the fallback,
    ///      never revert the collect.
    function _resolveTokenCreator(address token) private view returns (address) {
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
