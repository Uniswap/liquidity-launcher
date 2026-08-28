// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IClaimExecutor} from "../interfaces/IClaimExecutor.sol";

/// @notice The compounding recipient this guard forwards to.
interface ICompoundingRecipient {
    function minLiquidityIncrease() external view returns (uint128);
    function amounts(uint256 tokenId) external view returns (uint128 currency0Amount, uint128 currency1Amount);
    function claim(uint256 tokenId, uint256 minCurrency0Amount, uint256 minCurrency1Amount) external;
}

/// @title FullRangeGuardian
/// @notice Holds companion positions on the boundary ticks of a fixed set of full-range positions, and
///         releases liquidity from them for the duration of a compounding claim.
/// @dev The guarded set is recorded by `register` and an entry can never be replaced. `revokeDeployer`
///      closes the set permanently.
/// @custom:security-contact security@uniswap.org
contract FullRangeGuardian is IClaimExecutor, ReentrancyGuardTransient {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    /// @notice The two companion positions sharing a guarded position's boundary ticks
    /// @param lowerId Position whose `tickLower` matches the guarded position's `tickLower`
    /// @param upperId Position whose `tickUpper` matches the guarded position's `tickUpper`
    /// @dev Packed into one slot; v4 token ids sit far below uint128.
    struct Companions {
        uint128 lowerId;
        uint128 upperId;
    }

    /// @notice One guarded position and its two companions
    /// @param guardedTokenId The FeeSplitter-held full-range position
    /// @param companions The pair sharing its two boundary ticks
    struct GuardedPosition {
        uint256 guardedTokenId;
        Companions companions;
    }

    /// @notice The canonical v4 PositionManager
    IPositionManager public immutable positionManager;

    /// @notice The v4 PoolManager, read to pick the right `modifyLiquidities` entry point
    IPoolManager public immutable poolManager;

    /// @notice May transfer out the companion position NFTs
    /// @dev Not immutable, so it can be burned via `burnOwner`.
    address public owner;

    /// @notice The address that deployed this contract; the only one that may `register`
    address public deployer;

    /// @notice The compounding recipient behind each supported FeeSplitter, fixed at deployment.
    mapping(address feeSplitter => address compoundingRecipient) public compounderFor;

    /// @notice The companion positions recorded for each guarded position
    mapping(uint256 guardedTokenId => Companions) public companions;

    /// @dev Transient slots for the in-flight claim.
    bytes32 private constant TSLOT_TARGET = keccak256("FullRangeGuardian.target");
    bytes32 private constant TSLOT_SEARCHER = keccak256("FullRangeGuardian.searcher");

    /// @notice Emitted when a guarded position's claims begin routing through this contract
    /// @param guardedTokenId The guarded position
    /// @param compounder The recipient this contract claims from on its behalf
    event PositionGuarded(uint256 indexed guardedTokenId, address indexed compounder);

    /// @notice Emitted when the deployer is revoked and the guarded set becomes final
    event DeployerRevoked();

    /// @notice Emitted when the owner is burned and companion positions become permanently locked
    event OwnerBurned();

    /// @notice Thrown when the constructor arrays do not line up
    error ArrayLengthMismatch();
    /// @notice Thrown when a constructor argument that must be set is zero
    error ZeroAddress();
    /// @notice Thrown when the same target appears twice in the guarded set
    error DuplicateTarget(uint256 guardedTokenId);
    /// @notice Thrown when a companion id is the guarded position itself, or the two companions are equal
    error CompanionAliasesGuarded(uint256 guardedTokenId);
    /// @notice Thrown when the position was never guarded
    error NotGuarded(uint256 guardedTokenId);
    /// @notice Thrown when the position is not held by a supported FeeSplitter
    error UnsupportedHolder(uint256 guardedTokenId, address holder);
    /// @notice Thrown when `onClaimed` arrives from anything but the compounder we called
    error UnexpectedClaimCallback(address caller);
    /// @notice Thrown when a transfer is attempted by anyone but the owner
    error NotOwner(address caller);
    /// @notice Thrown when a registration is attempted by anyone but the deployer
    error NotDeployer(address caller);
    /// @notice Thrown when a token id in a registered entry is zero
    error ZeroTokenId(uint256 guardedTokenId);
    /// @notice Thrown when a companion named in a registered entry is not held by this contract
    error CompanionNotOwned(uint256 guardedTokenId, uint256 companionTokenId, address holder);

    /// @notice Thrown when PositionManager holds an unsettled delta on entry
    error PositionManagerDeltaNotZero(Currency currency, int256 delta);

    /// @param _positionManager The canonical v4 PositionManager
    /// @param _owner May transfer out the companion position NFTs
    /// @param feeSplitters The FeeSplitters whose positions this guard serves
    /// @param compounders The compounding recipient behind each of `feeSplitters`, index for index
    constructor(
        IPositionManager _positionManager,
        address _owner,
        address[] memory feeSplitters,
        address[] memory compounders
    ) {
        if (_owner == address(0)) revert ZeroAddress();
        if (feeSplitters.length != compounders.length) revert ArrayLengthMismatch();

        positionManager = _positionManager;
        poolManager = _positionManager.poolManager();
        owner = _owner;
        deployer = msg.sender;

        for (uint256 i; i < feeSplitters.length; i++) {
            if (feeSplitters[i] == address(0) || compounders[i] == address(0)) revert ZeroAddress();
            compounderFor[feeSplitters[i]] = compounders[i];
        }
    }

    /// @notice Records guarded positions and the companions that share their boundary ticks
    /// @dev Deployer-only. The companions must already be held by this contract.
    /// @param guarded The (guarded position, companions) pairs to record
    function register(GuardedPosition[] calldata guarded) external {
        if (msg.sender != deployer) revert NotDeployer(msg.sender);
        for (uint256 i; i < guarded.length; i++) {
            _register(guarded[i]);
        }
    }

    /// @notice Records one guarded position and its companions
    /// @param g The entry to record
    function _register(GuardedPosition memory g) private {
        uint256 lowerId = g.companions.lowerId;
        uint256 upperId = g.companions.upperId;

        if (companions[g.guardedTokenId].lowerId != 0) revert DuplicateTarget(g.guardedTokenId);
        if (g.guardedTokenId == 0 || lowerId == 0 || upperId == 0) revert ZeroTokenId(g.guardedTokenId);
        if (lowerId == g.guardedTokenId || upperId == g.guardedTokenId || lowerId == upperId) {
            revert CompanionAliasesGuarded(g.guardedTokenId);
        }

        _requireHeldHere(g.guardedTokenId, lowerId);
        _requireHeldHere(g.guardedTokenId, upperId);

        address holder = IERC721(address(positionManager)).ownerOf(g.guardedTokenId);
        address compounder = compounderFor[holder];
        if (compounder == address(0)) revert UnsupportedHolder(g.guardedTokenId, holder);

        companions[g.guardedTokenId] = g.companions;
        emit PositionGuarded(g.guardedTokenId, compounder);
    }

    /// @notice Receives native from a companion position decrease
    receive() external payable {}

    /// @notice Claims a guarded position's compounded fees
    /// @dev Mirrors `CompoundingClaimRecipient.claim`; `onClaimed` is invoked on the caller with the same
    ///      arguments. Releases `minLiquidityIncrease` from each companion.
    /// @param guardedTokenId The guarded position to claim for
    /// @param minCurrency0Amount Minimum currency0 to accept, forwarded verbatim
    /// @param minCurrency1Amount Minimum currency1 to accept, forwarded verbatim
    function claim(uint256 guardedTokenId, uint256 minCurrency0Amount, uint256 minCurrency1Amount)
        external
        nonReentrant
    {
        Companions memory b = companions[guardedTokenId];
        if (b.lowerId == 0) revert NotGuarded(guardedTokenId);

        address holder = IERC721(address(positionManager)).ownerOf(guardedTokenId);
        address compounder = compounderFor[holder];
        if (compounder == address(0)) revert UnsupportedHolder(guardedTokenId, holder);

        uint128 liquidityIncreaseAmount = ICompoundingRecipient(compounder).minLiquidityIncrease();
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(guardedTokenId);

        _decrease(key, b.lowerId, liquidityIncreaseAmount);
        _decrease(key, b.upperId, liquidityIncreaseAmount);

        _tset(TSLOT_TARGET, guardedTokenId);
        _tset(TSLOT_SEARCHER, uint256(uint160(msg.sender)));
        ICompoundingRecipient(compounder).claim(guardedTokenId, minCurrency0Amount, minCurrency1Amount);
        _tset(TSLOT_TARGET, 0);
        _tset(TSLOT_SEARCHER, 0);
    }

    /// @inheritdoc IClaimExecutor
    /// @dev Pass-through: forwards the payout and the callback to the caller of `claim`.
    function onClaimed(PoolKey memory poolKey, uint256 tokenId, uint256 currency0Received, uint256 currency1Received)
        external
        override
    {
        if (tokenId != _tget(TSLOT_TARGET)) revert UnexpectedClaimCallback(msg.sender);
        if (msg.sender != compounderFor[IERC721(address(positionManager)).ownerOf(tokenId)]) {
            revert UnexpectedClaimCallback(msg.sender);
        }

        address searcher = address(uint160(_tget(TSLOT_SEARCHER)));
        if (currency1Received != 0) poolKey.currency1.transfer(searcher, currency1Received);
        if (currency0Received != 0) poolKey.currency0.transfer(searcher, currency0Received);
        IClaimExecutor(searcher).onClaimed(poolKey, tokenId, currency0Received, currency1Received);
    }

    /// @notice Transfers a companion position NFT to the owner
    /// @param tokenId The companion position to transfer out
    function transferPosition(uint256 tokenId) external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        IERC721(address(positionManager)).transferFrom(address(this), owner, tokenId);
    }

    /// @notice Reverts unless this contract holds `companionTokenId`
    function _requireHeldHere(uint256 guardedTokenId, uint256 companionTokenId) private view {
        address companionHolder = IERC721(address(positionManager)).ownerOf(companionTokenId);
        if (companionHolder != address(this)) {
            revert CompanionNotOwned(guardedTokenId, companionTokenId, companionHolder);
        }
    }

    /// @notice Revokes the deployer, permanently giving up the ability to register further positions
    /// @dev One-way, and independent of `burnOwner`.
    function revokeDeployer() external {
        if (msg.sender != deployer) revert NotDeployer(msg.sender);
        deployer = address(0);
        emit DeployerRevoked();
    }

    /// @notice Burns the owner, permanently giving up the ability to transfer companion positions out
    /// @dev One-way. Afterwards the companion positions stay in this contract permanently.
    function burnOwner() external {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        owner = address(0);
        emit OwnerBurned();
    }

    /// @notice The amounts attributed to a guarded position and available to claim
    /// @dev Mirrors `IClaimableRecipient.amounts`, forwarding to the compounder.
    /// @param tokenId The guarded position
    /// @return currency0Amount The claimable currency0 amount
    /// @return currency1Amount The claimable currency1 amount
    function amounts(uint256 tokenId) external view returns (uint128 currency0Amount, uint128 currency1Amount) {
        address holder = IERC721(address(positionManager)).ownerOf(tokenId);
        address compounder = compounderFor[holder];
        if (compounder == address(0)) revert UnsupportedHolder(tokenId, holder);
        return ICompoundingRecipient(compounder).amounts(tokenId);
    }

    /// @notice Releases `liquidity` from a companion position
    function _decrease(PoolKey memory key, uint128 tokenId, uint128 liquidity) private {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(uint256(tokenId), liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        // modifyLiquidities opens its own lock, which reverts when the caller already holds one.
        if (poolManager.isUnlocked()) {
            // TAKE_PAIR resolves PositionManager's full credit, so require the account to be clear first.
            _requireNoPendingDelta(key.currency0);
            _requireNoPendingDelta(key.currency1);
            positionManager.modifyLiquiditiesWithoutUnlock(actions, params);
        } else {
            positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }
    }

    /// @notice Reverts unless PositionManager has no unsettled delta in `currency`
    function _requireNoPendingDelta(Currency currency) private view {
        int256 delta = poolManager.currencyDelta(address(positionManager), currency);
        if (delta != 0) revert PositionManagerDeltaNotZero(currency, delta);
    }

    /// @notice Writes a transient slot
    function _tset(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /// @notice Reads a transient slot
    function _tget(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
