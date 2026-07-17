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
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IBondingCurveLaunchHook, BondingCurveHookConfig} from "../interfaces/IBondingCurveLaunchHook.sol";
import {LaunchConfig} from "../interfaces/ILaunchHook.sol";
import {DirectLaunchParameters} from "../libraries/DirectLaunchParams.sol";
import {MigratorParams, PoolParameters} from "../libraries/MigratorParams.sol";
import {BondingCurveMath} from "../libraries/BondingCurveMath.sol";
import {DutchDecayConfig} from "../periphery/modules/DutchDecayFeeModule.sol";
import {BuybackAndBurnPositionRecipient} from "../periphery/BuybackAndBurnPositionRecipient.sol";
import {BondingCurvePositionManager} from "../periphery/BondingCurvePositionManager.sol";
import {PositionDefinition} from "../types/PositionPlannerTypes.sol";
import {DirectLaunchStrategy} from "./DirectLaunchStrategy.sol";

/// @title BondingCurveLaunchStrategy
/// @notice Launches a fixed-supply token through a finite curve before full-range graduation
/// @dev Price bounds and the matching curve/reserve split are fixed at deployment.
/// @custom:security-contact security@uniswap.org
contract BondingCurveLaunchStrategy is DirectLaunchStrategy, BlockNumberish {
    using SafeERC20 for IERC20;
    using MigratorParams for address;

    /// @notice Total token supply required for every launch.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    /// @notice Tick spacing used by bonding-curve pools.
    int24 public constant TICK_SPACING = 200;
    /// @notice Initial dynamic LP fee in pips.
    uint24 public constant START_FEE = 990_000;
    /// @notice Number of blocks over which the LP fee decays to zero.
    uint48 public constant DECAY_BLOCKS = 5;

    /// @notice Thrown when a caller other than the configured launcher initializes a distribution.
    error OnlyLauncher();
    /// @notice Thrown when caller-supplied configuration is provided.
    error UnexpectedConfigData();
    /// @notice Thrown when the supplied or reported token supply is not fixed.
    error InvalidSupply();
    /// @notice Thrown when the token does not use 18 decimals.
    error InvalidTokenDecimals();
    /// @notice Thrown when the configured ticks cannot define the curve.
    error InvalidTickRange();
    /// @notice Thrown when an address required by the strategy is zero.
    error ZeroAddress();

    /// @notice Emitted after the curve pool and its graduation contracts are created.
    /// @param poolId The identifier of the initialized pool.
    /// @param token The launched token.
    /// @param positionManager The per-launch manager that graduates the curve.
    /// @param finalPositionRecipient The permanent recipient of the graduated LP position.
    /// @param curveSupply The token amount placed in the finite curve position.
    /// @param reserveSupply The token amount reserved for full-range graduation.
    event BondingCurveTokenLaunched(
        PoolId indexed poolId,
        address indexed token,
        address indexed positionManager,
        address finalPositionRecipient,
        uint256 curveSupply,
        uint256 reserveSupply
    );

    /// @notice Launcher authorized to initialize distributions.
    address public immutable launcher;
    /// @notice Hook that freezes completed curves and controls graduation liquidity.
    IBondingCurveLaunchHook public immutable launchHook;
    /// @notice Dynamic fee module used during the launch window.
    address public immutable dynamicFeeModule;
    /// @notice Aligned tick at which the curve begins.
    int24 public immutable initialTick;
    /// @notice Aligned tick at which the curve is frozen for graduation.
    int24 public immutable graduationTick;
    /// @notice Initial pool square-root price.
    uint160 public immutable initialSqrtPriceX96;
    /// @notice Terminal pool square-root price.
    uint160 public immutable graduationSqrtPriceX96;
    /// @notice Token amount placed in the finite curve position.
    uint256 public immutable curveSupply;
    /// @notice Token amount reserved for full-range graduation.
    uint256 public immutable reserveSupply;

    constructor(
        address _launcher,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        IBondingCurveLaunchHook _launchHook,
        address _dynamicFeeModule,
        int24 _initialTick,
        int24 _graduationTick
    ) DirectLaunchStrategy(_positionManager, _poolManager) {
        // All launch collaborators are required and fixed across launches.
        if (
            _launcher == address(0) || address(_positionManager) == address(0) || address(_poolManager) == address(0)
                || address(_launchHook) == address(0) || _dynamicFeeModule == address(0)
        ) revert ZeroAddress();
        // Both ticks must be usable, aligned, and ordered for a token1 curve.
        if (
            _initialTick % TICK_SPACING != 0 || _graduationTick % TICK_SPACING != 0
                || _graduationTick <= TickMath.minUsableTick(TICK_SPACING)
                || _initialTick > TickMath.maxUsableTick(TICK_SPACING) || _graduationTick >= _initialTick
        ) revert InvalidTickRange();

        launcher = _launcher;
        launchHook = _launchHook;
        dynamicFeeModule = _dynamicFeeModule;
        initialTick = _initialTick;
        graduationTick = _graduationTick;
        initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_initialTick);
        graduationSqrtPriceX96 = TickMath.getSqrtPriceAtTick(_graduationTick);
        (curveSupply, reserveSupply) =
            BondingCurveMath.splitSupply(TOTAL_SUPPLY, initialSqrtPriceX96, graduationSqrtPriceX96, TICK_SPACING);
    }

    /// @inheritdoc DirectLaunchStrategy
    /// @dev Requires 100% of the token's fixed total supply. Caller configuration is not supported.
    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32)
        external
        override
        nonReentrant
    {
        // Only the configured launcher may use the immutable launch parameters.
        if (msg.sender != launcher) revert OnlyLauncher();
        if (configData.length != 0) revert UnexpectedConfigData();
        // Every supported token has a 1 billion supply and 18 decimals.
        if (totalSupply != TOTAL_SUPPLY || IERC20(token).totalSupply() != TOTAL_SUPPLY) revert InvalidSupply();
        if (IERC20Metadata(token).decimals() != 18) revert InvalidTokenDecimals();

        IERC20 launchToken = IERC20(token);
        uint256 balanceBefore = _pullTokenExact(token, msg.sender, TOTAL_SUPPLY);

        PoolKey memory key = _poolKey(token);
        uint256 curveTokenId = positionManager.nextTokenId();
        // The graduated LP NFT is permanently held by a token-specific fee recipient.
        BuybackAndBurnPositionRecipient finalPositionRecipient = new BuybackAndBurnPositionRecipient(
            token, address(0), address(0), positionManager, type(uint256).max, TOTAL_SUPPLY / 2_000
        );
        BondingCurvePositionManager curvePositionManager = new BondingCurvePositionManager(
            launchToken,
            positionManager,
            launchHook,
            key,
            curveTokenId,
            reserveSupply,
            address(finalPositionRecipient),
            initialSqrtPriceX96,
            graduationSqrtPriceX96
        );

        // Reserve one side of the final LP and initialize the finite curve.
        launchToken.safeTransfer(address(curvePositionManager), reserveSupply);
        (PoolId poolId,,) = _launch(token, curveSupply, _launchParameters(address(curvePositionManager)), balanceBefore);

        emit BondingCurveTokenLaunched(
            poolId, token, address(curvePositionManager), address(finalPositionRecipient), curveSupply, reserveSupply
        );
    }

    /// @notice Builds the direct-launch parameters for the finite curve position.
    /// @param curvePositionManager The recipient and custodian of the curve LP NFT.
    /// @return params The pool, curve position, fee, and hook configuration.
    function _launchParameters(address curvePositionManager)
        internal
        view
        virtual
        returns (DirectLaunchParameters memory params)
    {
        // Native ETH is currency0, so buys move from the initial tick toward the lower terminal tick.
        PositionDefinition[] memory positions = new PositionDefinition[](1);
        positions[0] = PositionDefinition({
            offsetLower: graduationTick - initialTick,
            offsetUpper: 0,
            weight: 10_000_000,
            overridePositionRecipient: address(0)
        });
        uint48 swapStartBlock = uint48(_getBlockNumberish());

        params = DirectLaunchParameters({
            currency: address(0),
            initialSqrtPriceX96: initialSqrtPriceX96,
            recipient: curvePositionManager,
            positionRecipient: curvePositionManager,
            poolParameters: PoolParameters({
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: TICK_SPACING, hook: address(launchHook)
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
                    ),
                    hookConfig: abi.encode(
                        BondingCurveHookConfig({
                            manager: curvePositionManager,
                            graduationSqrtPriceX96: graduationSqrtPriceX96,
                            curveTickLower: graduationTick,
                            curveTickUpper: initialTick
                        })
                    )
                })
            )
        });
    }

    /// @notice Initializes the fixed finite curve and mints its single position.
    function _launch(address token, uint256 totalSupply, DirectLaunchParameters memory params, uint256 balanceBefore)
        internal
        virtual
        override
        returns (PoolId poolId, PoolKey memory key, bytes memory plan)
    {
        _validateTokenAmount(token, totalSupply);
        Currency tokenCurrency = Currency.wrap(token);
        uint256 balance = tokenCurrency.balanceOfSelf();
        uint256 available = balance >= balanceBefore ? balance - balanceBefore : 0;
        if (available != totalSupply) revert TokenAmountMismatch(available, totalSupply);

        key = _poolKey(token);
        poolId = key.toId();
        address(launchHook).validateHook(LPFeeLibrary.DYNAMIC_FEE_FLAG, poolId, poolManager);
        LaunchConfig memory config = abi.decode(params.launchConfig, (LaunchConfig));
        config.tokenIsCurrency0 = false;
        launchHook.setLaunchConfig(poolId, config);
        poolManager.initialize(key, initialSqrtPriceX96);

        uint128 tokenTransferAmount;
        (plan, tokenTransferAmount) =
            _curvePositionPlan(key, SafeCastLib.toUint128(totalSupply), params.positionRecipient);
        tokenCurrency.transfer(address(positionManager), tokenTransferAmount);
        positionManager.modifyLiquidities(plan, block.timestamp);

        balance = tokenCurrency.balanceOfSelf();
        uint256 unplaced = balance >= balanceBefore ? balance - balanceBefore : 0;
        _sweepToken(tokenCurrency, params.recipient, unplaced);
        emit TokenLaunched(poolId, token, key, initialSqrtPriceX96, plan);
    }

    function _curvePositionPlan(PoolKey memory key, uint128 tokenAmount, address recipient)
        private
        view
        returns (bytes memory plan, uint128 tokenTransferAmount)
    {
        uint256 liquidity = FullMath.mulDiv(tokenAmount, FixedPoint96.Q96, initialSqrtPriceX96 - graduationSqrtPriceX96);
        uint128 maxLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
        uint128 positionLiquidity = liquidity > maxLiquidity ? maxLiquidity : SafeCastLib.toUint128(liquidity);
        tokenTransferAmount = SafeCastLib.toUint128(
            SqrtPriceMath.getAmount1Delta(graduationSqrtPriceX96, initialSqrtPriceX96, positionLiquidity, true)
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory actionParams = new bytes[](4);
        actionParams[0] = abi.encode(
            key, graduationTick, initialTick, positionLiquidity, uint128(0), tokenTransferAmount, recipient, bytes("")
        );
        actionParams[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        actionParams[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        actionParams[3] = abi.encode(key.currency0, key.currency1, ActionConstants.MSG_SENDER);
        plan = abi.encode(actions, actionParams);
    }

    function _poolKey(address token) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(launchHook))
        });
    }
}
