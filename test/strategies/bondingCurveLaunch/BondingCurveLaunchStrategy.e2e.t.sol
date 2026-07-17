// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BondingCurveLaunchStrategy} from "../../../src/strategies/BondingCurveLaunchStrategy.sol";
import {BondingCurveLaunchHook} from "../../../src/periphery/hooks/BondingCurveLaunchHook.sol";
import {BondingCurvePositionManager} from "../../../src/periphery/BondingCurvePositionManager.sol";
import {DutchDecayFeeModule} from "../../../src/periphery/modules/DutchDecayFeeModule.sol";
import {BuybackAndBurnPositionRecipient} from "../../../src/periphery/BuybackAndBurnPositionRecipient.sol";
import {BondingCurvePhase, IBondingCurveLaunchHook} from "../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// @notice BTT integration coverage for the complete bonding-curve lifecycle
///
/// initializeDistribution
/// └── when the configured ticks imply an approximately 80/20 split
///     ├── it reuses DirectLaunchStrategy to mint one finite curve position
///     ├── it reserves the matching token supply in a per-launch manager
///     └── it rejects external liquidity while the curve is active
///
/// graduate
/// ├── when the curve has not reached its terminal price
/// │   └── it reverts
/// └── when a buy reaches the terminal price
///     ├── it freezes subsequent swaps
///     ├── it burns the curve position
///     ├── it mints one permanently owned full-range position
///     └── it reopens swaps
contract BondingCurveLaunchStrategyE2ETest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    int24 internal constant INITIAL_TICK = 122_000;
    int24 internal constant GRADUATION_TICK = 94_200;

    BondingCurveLaunchHook internal launchHook;
    BondingCurveLaunchStrategy internal strategy;
    DutchDecayFeeModule internal feeModule;
    PoolSwapTest internal swapRouter;

    function setUp() public {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );

        feeModule = new DutchDecayFeeModule();
        address predictedStrategy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this), flags, type(BondingCurveLaunchHook).creationCode, abi.encode(POOL_MANAGER, predictedStrategy)
        );
        strategy = new BondingCurveLaunchStrategy(
            address(this),
            POSITION_MANAGER,
            POOL_MANAGER,
            IBondingCurveLaunchHook(hookAddress),
            address(feeModule),
            INITIAL_TICK,
            GRADUATION_TICK
        );
        assertEq(address(strategy), predictedStrategy);
        launchHook = new BondingCurveLaunchHook{salt: salt}(POOL_MANAGER, address(strategy));
        assertEq(address(launchHook), hookAddress);
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        vm.deal(address(this), 100_000 ether);
    }

    function test_initializeDistribution_mintsFiniteCurveAndReservesMatchingSupply() public {
        (MockERC20 token, PoolKey memory key, BondingCurvePositionManager manager) = _launch();

        assertApproxEqRel(strategy.curveSupply(), strategy.TOTAL_SUPPLY() * 80 / 100, 6e15);
        assertEq(strategy.curveSupply() + strategy.reserveSupply(), strategy.TOTAL_SUPPLY());
        assertGe(token.balanceOf(address(manager)), strategy.reserveSupply());
        assertEq(uint256(launchHook.bondingCurvePhase(key.toId())), uint256(BondingCurvePhase.Active));

        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(manager.curveTokenId());
        assertEq(info.tickLower(), GRADUATION_TICK);
        assertEq(info.tickUpper(), INITIAL_TICK);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(manager.curveTokenId()), address(manager));
    }

    function test_graduate_revertsBeforeTerminalPrice() public {
        (,, BondingCurvePositionManager manager) = _launch();

        vm.expectRevert(IBondingCurveLaunchHook.GraduationNotReady.selector);
        manager.graduate();
    }

    function test_graduate_burnsCurveMintsFullRangeAndReopensSwaps() public {
        (MockERC20 token, PoolKey memory key, BondingCurvePositionManager manager) = _launch();
        vm.roll(block.number + strategy.DECAY_BLOCKS());
        uint256 forcedTokenAmount = 123;
        deal(address(token), address(manager), token.balanceOf(address(manager)) + forcedTokenAmount, false);
        vm.deal(address(manager), 1 ether);
        address finalPositionRecipient = manager.finalPositionRecipient();
        uint256 burnedTokenBefore = token.balanceOf(address(0xdead));
        uint256 buybackNativeBefore = finalPositionRecipient.balance;

        swapRouter.swap{value: 100_000 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -100_000 ether, sqrtPriceLimitX96: strategy.graduationSqrtPriceX96()
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(sqrtPriceX96, strategy.graduationSqrtPriceX96());
        uint160 initialSqrtPriceX96 = strategy.initialSqrtPriceX96();
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(launchHook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IBondingCurveLaunchHook.GraduationPending.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: initialSqrtPriceX96}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        uint256 finalTokenId = POSITION_MANAGER.nextTokenId();
        uint256 curveTokenId = manager.curveTokenId();
        manager.graduate();

        assertTrue(manager.graduated());
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
        assertGe(token.balanceOf(address(0xdead)) - burnedTokenBefore, forcedTokenAmount);
        assertGe(finalPositionRecipient.balance - buybackNativeBefore, 1 ether);
        assertEq(uint256(launchHook.bondingCurvePhase(key.toId())), uint256(BondingCurvePhase.Graduated));
        vm.expectRevert(BondingCurvePositionManager.AlreadyGraduated.selector);
        manager.graduate();
        vm.expectRevert();
        IERC721(address(POSITION_MANAGER)).ownerOf(curveTokenId);

        address finalRecipient = IERC721(address(POSITION_MANAGER)).ownerOf(finalTokenId);
        assertEq(finalRecipient, manager.finalPositionRecipient());
        BuybackAndBurnPositionRecipient recipient = BuybackAndBurnPositionRecipient(payable(finalRecipient));
        assertEq(recipient.operator(), address(0));
        assertEq(recipient.timelockBlockNumber(), type(uint256).max);
        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(finalTokenId);
        assertEq(info.tickLower(), TickMath.minUsableTick(strategy.TICK_SPACING()));
        assertEq(info.tickUpper(), TickMath.maxUsableTick(strategy.TICK_SPACING()));
        assertEq(token.balanceOf(address(strategy)), 0);

        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function _launch() private returns (MockERC20 token, PoolKey memory key, BondingCurvePositionManager manager) {
        token = new MockERC20("Bonding Token", "BOND", strategy.TOTAL_SUPPLY(), address(this));
        token.approve(address(strategy), strategy.TOTAL_SUPPLY());
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(address(launchHook))
        });
        uint256 curveTokenId = POSITION_MANAGER.nextTokenId();
        strategy.initializeDistribution(address(token), strategy.TOTAL_SUPPLY(), bytes(""), bytes32(0));
        manager = BondingCurvePositionManager(payable(IERC721(address(POSITION_MANAGER)).ownerOf(curveTokenId)));
    }

    receive() external payable {}
}
