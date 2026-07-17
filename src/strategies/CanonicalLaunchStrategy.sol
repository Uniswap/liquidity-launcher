// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {LaunchConfig} from "../interfaces/ILaunchHook.sol";
import {DirectLaunchParameters} from "../libraries/DirectLaunchParams.sol";
import {PoolParameters} from "../libraries/MigratorParams.sol";
import {DutchDecayConfig} from "../periphery/modules/DutchDecayFeeModule.sol";
import {BuybackAndBurnPositionRecipient} from "../periphery/BuybackAndBurnPositionRecipient.sol";
import {PositionDefinition} from "../types/PositionPlannerTypes.sol";
import {DirectLaunchStrategy} from "./DirectLaunchStrategy.sol";

/// @title CanonicalLaunchStrategy
/// @notice Launches a fixed-supply token into a canonical native-currency pool
/// @dev Pool, position, fee, and LP custody parameters are fixed at deployment or in contract constants.
/// @custom:security-contact security@uniswap.org
contract CanonicalLaunchStrategy is IStrategy, BlockNumberish, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Total token supply required for every launch.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    /// @notice Tick spacing used by canonical pools.
    int24 public constant TICK_SPACING = 200;
    /// @notice Initial dynamic LP fee in pips.
    uint24 public constant START_FEE = 990_000;
    /// @notice Number of blocks over which the LP fee decays to zero.
    uint48 public constant DECAY_BLOCKS = 5;
    address private constant BURN_ADDRESS = address(0xdead);

    /// @notice Thrown when a caller other than the canonical launcher initializes a distribution.
    error OnlyLauncher();
    /// @notice Thrown when caller-supplied configuration is provided.
    error UnexpectedConfigData();
    /// @notice Thrown when the supplied or reported token supply is not canonical.
    error InvalidSupply();
    /// @notice Thrown when the token does not use 18 decimals.
    error InvalidTokenDecimals();
    /// @notice Thrown when an address required by the strategy is zero.
    error ZeroAddress();
    /// @notice Thrown when the initial tick is invalid or not aligned to the canonical tick spacing.
    error InvalidInitialTick();
    /// @notice Thrown when the strategy receives an unexpected token amount.
    error TokenAmountMismatch();
    /// @notice Thrown when the underlying strategy does not consume its full allowance.
    error AllowanceNotFullyConsumed();
    /// @notice Thrown when tokens remain after the launch.
    error UnplacedTokens();

    /// @notice Emitted after a canonical pool and its permanent position recipient are created.
    /// @param poolId The identifier of the initialized canonical pool.
    /// @param token The launched token.
    /// @param positionRecipient The permanent recipient of the pool's LP position.
    event CanonicalTokenLaunched(PoolId indexed poolId, address indexed token, address indexed positionRecipient);

    /// @notice Launcher authorized to initialize distributions.
    address public immutable launcher;
    /// @notice General direct-launch strategy used to initialize pools and positions.
    DirectLaunchStrategy public immutable directLaunchStrategy;
    /// @notice Hook used by canonical pools.
    address public immutable launchHook;
    /// @notice Dynamic fee module used during the launch window.
    address public immutable dynamicFeeModule;
    /// @notice Position manager that owns canonical LP NFTs.
    IPositionManager public immutable positionManager;
    /// @notice Initial aligned pool tick.
    int24 public immutable initialTick;
    /// @notice Initial pool square-root price.
    uint160 public immutable initialSqrtPriceX96;

    constructor(
        address _launcher,
        DirectLaunchStrategy _directLaunchStrategy,
        address _launchHook,
        address _dynamicFeeModule,
        int24 _initialTick
    ) {
        // All protocol collaborators are required and fixed for every launch.
        if (
            _launcher == address(0) || address(_directLaunchStrategy) == address(0) || _launchHook == address(0)
                || _dynamicFeeModule == address(0)
        ) revert ZeroAddress();
        // The initial tick must be usable and leave a non-empty token-side range.
        if (
            _initialTick % TICK_SPACING != 0 || _initialTick <= TickMath.minUsableTick(TICK_SPACING)
                || _initialTick > TickMath.maxUsableTick(TICK_SPACING)
        ) revert InvalidInitialTick();

        launcher = _launcher;
        directLaunchStrategy = _directLaunchStrategy;
        launchHook = _launchHook;
        dynamicFeeModule = _dynamicFeeModule;
        positionManager = _directLaunchStrategy.positionManager();
        initialTick = _initialTick;
        initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_initialTick);
    }

    /// @inheritdoc IStrategy
    /// @dev Requires 100% of the token's fixed total supply in one distribution. Caller configuration is not
    ///      supported.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        override
        nonReentrant
    {
        // Only the configured launcher may use this strategy with its fixed parameters.
        if (msg.sender != launcher) revert OnlyLauncher();
        if (configData.length != 0) revert UnexpectedConfigData();

        // Canonical tokens have a 1 billion token supply and 18 decimals.
        if (totalSupply != TOTAL_SUPPLY || IERC20(token).totalSupply() != TOTAL_SUPPLY) revert InvalidSupply();
        if (IERC20Metadata(token).decimals() != 18) revert InvalidTokenDecimals();

        // Verify the exact distribution without consuming any pre-existing balance.
        IERC20 launchToken = IERC20(token);
        uint256 balanceBefore = launchToken.balanceOf(address(this));
        launchToken.safeTransferFrom(msg.sender, address(this), TOTAL_SUPPLY);
        uint256 balanceAfterTransfer = launchToken.balanceOf(address(this));
        if (balanceAfterTransfer < balanceBefore || balanceAfterTransfer - balanceBefore != TOTAL_SUPPLY) {
            revert TokenAmountMismatch();
        }

        // Permanently custody the LP position in a token-specific fee recipient.
        BuybackAndBurnPositionRecipient positionRecipient = new BuybackAndBurnPositionRecipient(
            token, address(0), address(0), positionManager, type(uint256).max, TOTAL_SUPPLY / 2_000
        );

        // Use DirectLaunchStrategy for pool initialization and position minting.
        launchToken.forceApprove(address(directLaunchStrategy), TOTAL_SUPPLY);
        DirectLaunchParameters memory params = _launchParameters(address(positionRecipient));
        directLaunchStrategy.initializeDistribution(token, TOTAL_SUPPLY, abi.encode(params), bytes32(0));

        // Reject incomplete transfers or tokens returned to this contract.
        if (launchToken.allowance(address(this), address(directLaunchStrategy)) != 0) {
            revert AllowanceNotFullyConsumed();
        }
        if (launchToken.balanceOf(address(this)) != balanceBefore) revert UnplacedTokens();

        // Derive the pool ID emitted for this launch.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(launchHook)
        });
        emit CanonicalTokenLaunched(key.toId(), token, address(positionRecipient));
    }

    /// @notice Builds the direct-launch parameters for a canonical pool
    /// @dev Uses native ETH, tick spacing 200, one token-side position, and a dynamic fee that starts at 99% and
    ///      decays to zero over five blocks.
    /// @param positionRecipient The permanent recipient of the LP position
    /// @return params The pool, position, and fee configuration
    function _launchParameters(address positionRecipient) private view returns (DirectLaunchParameters memory params) {
        uint48 swapStartBlock = uint48(_getBlockNumberish());

        // Native ETH is currency0, so token liquidity ranges from the minimum tick to the initial tick.
        PositionDefinition[] memory positions = new PositionDefinition[](1);
        positions[0] = PositionDefinition({
            offsetLower: TickMath.minUsableTick(TICK_SPACING) - initialTick,
            offsetUpper: 0,
            weight: 10_000_000,
            overridePositionRecipient: address(0)
        });

        params = DirectLaunchParameters({
            currency: address(0),
            initialSqrtPriceX96: initialSqrtPriceX96,
            recipient: BURN_ADDRESS,
            positionRecipient: positionRecipient,
            poolParameters: PoolParameters({
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: TICK_SPACING, hook: launchHook
            }),
            positionDefinitions: abi.encode(positions),
            launchConfig: abi.encode(
                LaunchConfig({
                    swapStartBlock: swapStartBlock,
                    windowEndBlock: swapStartBlock + DECAY_BLOCKS,
                    baseFee: 0,
                    tokenIsCurrency0: false,
                    module: dynamicFeeModule,
                    moduleConfig: abi.encode(
                        DutchDecayConfig({
                            startFee: START_FEE, endFee: 0, decayBlocks: DECAY_BLOCKS, taxBothDirections: true
                        })
                    )
                })
            )
        });
    }
}
