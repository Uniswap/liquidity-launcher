// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @dev Sentinel recipient that resolves, per pool, to the UERC20 `creator()` of the pool's token.
address constant CREATOR_SENTINEL = address(uint160(uint256(keccak256("FeeSplitter.CREATOR"))));

/// @notice A single fee allocation: `bps` of one currency side to `recipient`.
/// @param recipient The receiver of this share; may be the CREATOR sentinel.
/// @param bps The share in basis points. Each side's splits sum to 10,000.
struct FeeSplit {
    address recipient;
    uint16 bps;
}

/// @title IFeeSplitter
/// @notice Singleton, immutable-configuration custodian of v4 native-ETH LP positions that
///         permissionlessly collects their fees and pushes them to fixed recipients.
interface IFeeSplitter {
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

    /// @notice Thrown when a side's splits do not sum to the bps denominator.
    /// @param totalBps The invalid total.
    error InvalidSplitTotal(uint256 totalBps);

    /// @notice Thrown when collectFees is called with no token IDs.
    error NoTokenIds();

    /// @notice Thrown when a position's currency0 is not native ETH.
    /// @param tokenId The offending position.
    /// @param currency0 The unexpected currency0.
    error InvalidBaseCurrency(uint256 tokenId, Currency currency0);

    /// @notice Collects the accrued fees of each position and pushes the configured splits.
    /// @dev Permissionless. Each position is collected and distributed individually so fees are
    ///      attributed to that pool's token and creator. Positions must be native-ETH pairs and be
    ///      owned by (or approved to) the splitter, otherwise the PositionManager reverts.
    /// @param tokenIds The position token IDs to collect.
    function collectFees(uint256[] calldata tokenIds) external;

    /// @notice The canonical v4 PositionManager holding the LP positions.
    function positionManager() external view returns (IPositionManager);

    /// @notice Receives any native ETH share that cannot be delivered (unresolvable creator, failed send).
    function nativeFallback() external view returns (address);

    /// @notice Receives any token share whose CREATOR recipient cannot be resolved.
    function tokenFallback() external view returns (address);

    /// @notice The native ETH (currency0) split at `index`.
    function nativeSplits(uint256 index) external view returns (address recipient, uint16 bps);

    /// @notice The token (currency1) split at `index`.
    function tokenSplits(uint256 index) external view returns (address recipient, uint16 bps);

    /// @notice The full configured native ETH (currency0) splits.
    function getNativeSplits() external view returns (FeeSplit[] memory);

    /// @notice The full configured token (currency1) splits.
    function getTokenSplits() external view returns (FeeSplit[] memory);
}
