// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice One recipient's fee allocation: independent shares of both currency sides.
/// @param recipient The receiver of these shares; appears at most once in the splits.
/// @param quoteBps The quote currency share in basis points. All quoteBps sum to 10,000.
/// @param tokenBps The token-side share in basis points. All tokenBps sum to 10,000.
/// @param useCallback Whether the recipient is notified after receiving a fee share.
struct FeeSplit {
    address recipient;
    uint16 quoteBps;
    uint16 tokenBps;
    bool useCallback;
}

/// @title IFeeSplitter
/// @notice Immutable-configuration custodian of v4 LP positions pairing a configured quote currency
///         that permissionlessly collects their fees and pushes them to fixed recipients.
interface IFeeSplitter {
    /// @notice Emitted once per collected position.
    /// @param tokenId The position collected.
    /// @param token The pool's token-side currency (the side that is not the quote).
    /// @param quoteAmount The quote currency fees collected.
    /// @param tokenAmount The token-side fees collected.
    event FeesCollected(uint256 indexed tokenId, address indexed token, uint256 quoteAmount, uint256 tokenAmount);

    /// @notice Emitted for each nonzero amount pushed to a recipient. Native pushes are force-sent,
    ///         so the recipient is always the configured one.
    /// @param recipient The receiver of the share.
    /// @param currency The currency sent; address(0) is native ETH.
    /// @param amount The amount sent.
    event FeesForwarded(address indexed recipient, Currency indexed currency, uint256 amount);

    /// @notice Thrown when a balance exceeds the maximum allowed.
    /// @param tokenId The position whose collection realized the balance.
    error BalanceExceedsMaxAllowed(uint256 tokenId);

    /// @notice Thrown when no splits are configured.
    error NoSplits();

    /// @notice Thrown when a split recipient is the zero address or this contract.
    /// @param recipient The invalid recipient.
    error InvalidRecipient(address recipient);

    /// @notice Thrown when a callback-enabled split recipient has no deployed code.
    /// @param recipient The invalid callback recipient.
    error CallbackRecipientNotContract(address recipient);

    /// @notice Thrown when a split has zero basis points on both sides.
    /// @param recipient The recipient of the empty split.
    error ZeroSplitBps(address recipient);

    /// @notice Thrown when a recipient appears twice in the splits.
    /// @param recipient The duplicated recipient.
    error DuplicateRecipient(address recipient);

    /// @notice Thrown when a side's shares do not sum to the bps denominator.
    /// @param totalBps The invalid side total.
    error InvalidSplitTotal(uint256 totalBps);

    /// @notice Thrown when collectFees is called with no token IDs.
    error NoTokenIds();

    /// @notice Thrown when neither of a position's pool currencies is the quote currency.
    /// @param tokenId The offending position.
    error QuoteCurrencyNotInPool(uint256 tokenId);

    /// @notice Thrown when an NFT other than a canonical PositionManager position is safe-transferred in.
    /// @param sender The rejected caller of onERC721Received.
    error NotPositionManager(address sender);

    /// @notice Thrown when this contract does not own the position being collected or increased.
    /// @param tokenId The position token ID.
    error NotOwner(uint256 tokenId);

    /// @notice Thrown when a position still has uncollected fees at an increase.
    /// @param tokenId The position token ID.
    error UncollectedFees(uint256 tokenId);

    /// @notice Thrown when collectFees is called while the PoolManager is already unlocked.
    error PoolManagerAlreadyUnlocked();

    /// @notice Collects the accrued fees of each position and pushes the configured splits.
    /// @dev Permissionless. Each position's pool must contain the quote currency and the position
    ///      must be owned by the splitter. A recipient that reverts its notification
    ///      reverts this call, leaving those fees in the pool; other token IDs are unaffected.
    ///      Unlike `increaseLiquidity`, collection cannot run inside an existing PoolManager unlock:
    ///      it reverts with PoolManagerAlreadyUnlocked so recipients are never notified mid-lock.
    /// @param tokenIds The position token IDs to collect.
    function collectFees(uint256[] calldata tokenIds) external;

    /// @notice Increases the liquidity of a position held by the splitter using funds already sent to
    ///         the PositionManager; excess funding is taken back to the caller.
    /// @dev Permissionless. All fees MUST be collected first; reverts with UncollectedFees otherwise.
    ///      If the PoolManager is already unlocked the actions run in that lock, so the increase can be
    ///      funded from a flash loan. Such callers MUST open the lock via `poolManager.unlock()` (entering
    ///      through `PositionManager.modifyLiquidities` reverts ContractLocked) and increase before swapping.
    /// @param tokenId The position to increase.
    /// @param liquidity The liquidity to add.
    /// @param amount0Max The maximum currency0 to spend.
    /// @param amount1Max The maximum currency1 to spend.
    /// @param hookData Arbitrary data passed to the pool's hooks.
    function increaseLiquidity(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        bytes calldata hookData
    ) external;

    /// @notice The canonical v4 PositionManager holding the LP positions.
    /// @return The PositionManager this splitter collects through.
    function positionManager() external view returns (IPositionManager);

    /// @notice The quote currency every serviced position must pair on one side.
    /// @return The quote currency; the wrapped address is zero for the chain's native currency.
    function quoteCurrency() external view returns (Currency);

    /// @notice The full immutable split configuration.
    /// @return The configured fee splits.
    function getSplits() external view returns (FeeSplit[] memory);
}
