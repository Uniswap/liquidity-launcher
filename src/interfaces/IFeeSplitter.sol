// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice One recipient's fee allocation: independent shares of both currency sides.
/// @param recipient The receiver of these shares; appears at most once in the splits.
/// @param nativeBps The native ETH (currency0) share in basis points. All nativeBps sum to 10,000.
/// @param tokenBps The token (currency1) share in basis points. All tokenBps sum to 10,000.
/// @param useCallback Whether the recipient is notified after receiving a fee share.
struct FeeSplit {
    address recipient;
    uint16 nativeBps;
    uint16 tokenBps;
    bool useCallback;
}

/// @title IFeeSplitter
/// @notice Immutable-configuration custodian of v4 native-ETH LP positions that permissionlessly
///         collects their fees and pushes them to fixed recipients.
interface IFeeSplitter {
    /// @notice Emitted once per collected position.
    /// @param tokenId The position collected.
    /// @param token The pool's currency1.
    /// @param nativeAmount The native ETH fees collected.
    /// @param tokenAmount The token fees collected.
    event FeesCollected(uint256 indexed tokenId, address indexed token, uint256 nativeAmount, uint256 tokenAmount);

    /// @notice Emitted for each nonzero amount pushed to a recipient. Native pushes are force-sent,
    ///         so the recipient is always the configured one.
    /// @param recipient The receiver of the share.
    /// @param currency The currency sent; address(0) is native ETH.
    /// @param amount The amount sent.
    event FeesForwarded(address indexed recipient, Currency indexed currency, uint256 amount);

    /// @notice Thrown when a balance exceeds the maximum allowed.
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

    /// @notice Thrown when a position's currency0 is not native ETH.
    /// @param tokenId The offending position.
    /// @param currency0 The unexpected currency0.
    error InvalidBaseCurrency(uint256 tokenId, Currency currency0);

    /// @notice Thrown when an NFT other than a canonical PositionManager position is safe-transferred in.
    /// @param sender The rejected caller of onERC721Received.
    error NotPositionManager(address sender);

    /// @notice Thrown when this contract does not own the position being increased.
    /// @param tokenId The position token ID.
    error NotOwner(uint256 tokenId);

    /// @notice Thrown when a position still has uncollected fees at an increase.
    /// @param tokenId The position token ID.
    error UncollectedFees(uint256 tokenId);

    /// @notice Collects the accrued fees of each position and pushes the configured splits.
    /// @dev Permissionless. Positions must be native-ETH pairs and be owned by (or approved to) the
    ///      splitter, otherwise the PositionManager reverts. A callback recipient that fails to accept
    ///      its notification reverts the whole call, leaving those fees unrealized in the pool; since
    ///      each position is independent, the remaining token IDs can still be collected on their own.
    /// @param tokenIds The position token IDs to collect.
    function collectFees(uint256[] calldata tokenIds) external;

    /// @notice Increases the liquidity of a position held by the splitter using funds already sent to
    ///         the PositionManager; excess funding is taken back to the caller.
    /// @dev Permissionless. All fees MUST be collected first; reverts with UncollectedFees otherwise.
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
    function positionManager() external view returns (IPositionManager);

    /// @notice The full immutable split configuration.
    function getSplits() external view returns (FeeSplit[] memory);
}
