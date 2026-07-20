// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Ported from the pre-rearch BondingCurveLaunchStrategy.e2e.t.sol. The pool-level behaviour assertions
// are unchanged; only the setup surface (constructors, launch entrypoint, typed config, phase enum,
// DECAY_BLOCKS location) is adapted to the bonding-curve-only rearchitecture.

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BondingCurveLaunchStrategy} from "../../../src/strategies/BondingCurveLaunchStrategy.sol";
import {BondingCurveLaunchHook} from "../../../src/periphery/hooks/BondingCurveLaunchHook.sol";
import {DutchDecayFeeModule} from "../../../src/periphery/modules/DutchDecayFeeModule.sol";
import {BuybackAndBurnPositionRecipient} from "../../../src/periphery/BuybackAndBurnPositionRecipient.sol";
import {IBondingCurveLaunchHook} from "../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {BondingCurvePhase} from "../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract SharedDeltaAttacker is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    IPositionManager internal immutable positionManager;
    address internal attacker;
    uint256 internal terminalBudget;

    constructor(IPoolManager _manager, IPositionManager _positionManager) {
        manager = _manager;
        positionManager = _positionManager;
    }

    function attack(PoolKey calldata curveKey, PoolKey calldata sideKey, uint256 nativeDebt) external payable {
        attacker = msg.sender;
        terminalBudget = msg.value;
        manager.unlock(abi.encode(curveKey, sideKey, nativeDebt));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert();
        (PoolKey memory curveKey, PoolKey memory sideKey, uint256 nativeDebt) =
            abi.decode(data, (PoolKey, PoolKey, uint256));

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(60), TickMath.getSqrtPriceAtTick(120), nativeDebt
        );
        bytes[] memory mintParams = new bytes[](1);
        mintParams[0] = abi.encode(
            sideKey, int24(60), int24(120), liquidity, uint128(nativeDebt), uint128(0), address(this), bytes("")
        );
        positionManager.modifyLiquiditiesWithoutUnlock(abi.encodePacked(uint8(Actions.MINT_POSITION)), mintParams);

        if (manager.currencyDelta(address(positionManager), sideKey.currency0) >= 0) revert();
        manager.swap(
            curveKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(terminalBudget),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            bytes("")
        );
        if (manager.currencyDelta(address(positionManager), curveKey.currency0) != 0) revert();

        int256 nativeDelta = manager.currencyDelta(address(this), curveKey.currency0);
        if (nativeDelta >= 0) revert();
        manager.settle{value: uint256(-nativeDelta)}();

        int256 tokenDelta = manager.currencyDelta(address(this), curveKey.currency1);
        if (tokenDelta <= 0) revert();
        manager.take(curveKey.currency1, attacker, uint256(tokenDelta));
        return bytes("");
    }

    receive() external payable {}
}

/// @notice Rearch e2e: the same bonding-curve lifecycle assertions against BondingCurveLaunchStrategy/BondingCurveLaunchHook.
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

        feeModule = new DutchDecayFeeModule(990_000, 0, 5, true);

        address predictedStrategy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(BondingCurveLaunchHook).creationCode,
            abi.encode(POOL_MANAGER, POSITION_MANAGER, predictedStrategy)
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
        launchHook = new BondingCurveLaunchHook{salt: salt}(POOL_MANAGER, POSITION_MANAGER, address(strategy));
        assertEq(address(launchHook), hookAddress);
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        vm.deal(address(this), 100_000 ether);
    }

    function test_launch_mintsFiniteCurveAndReservesMatchingSupply() public {
        (MockERC20 token, PoolKey memory key, uint256 curveTokenId) = _launch();

        assertApproxEqRel(strategy.curveSupply(), strategy.TOTAL_SUPPLY() * 80 / 100, 6e15);
        assertEq(strategy.curveSupply() + strategy.reserveSupply(), strategy.TOTAL_SUPPLY());
        assertGe(token.balanceOf(address(launchHook)), strategy.reserveSupply());
        assertEq(uint256(launchHook.bondingCurvePhase(key.toId())), uint256(BondingCurvePhase.Active));

        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(curveTokenId);
        assertEq(info.tickLower(), GRADUATION_TICK);
        assertEq(info.tickUpper(), INITIAL_TICK);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(curveTokenId), address(launchHook));
    }

    function test_swap_revertsWhenExactOutputExceedsRemainingCurve() public {
        (, PoolKey memory key,) = _launch();
        vm.roll(block.number + feeModule.decayBlocks());
        int256 requestedOutput = int256(strategy.curveSupply() + 1);

        vm.expectRevert();
        swapRouter.swap{value: 100_000 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: requestedOutput, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function test_swapExactOutput_succeedsAtInitialCurveBoundary() public {
        (MockERC20 token, PoolKey memory key,) = _launch();
        vm.roll(block.number + feeModule.decayBlocks());
        uint256 requestedOutput = 1 ether;
        uint256 balanceBefore = token.balanceOf(address(this));

        BalanceDelta delta = swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(requestedOutput),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        assertLt(delta.amount0(), 0);
        assertEq(delta.amount1(), int128(uint128(requestedOutput)));
        assertEq(token.balanceOf(address(this)) - balanceBefore, requestedOutput);
    }

    function test_swapExactInput_partiallyFillsAndGraduatesAtomically() public {
        (MockERC20 token, PoolKey memory key, uint256 curveTokenId) = _launch();
        vm.roll(block.number + feeModule.decayBlocks());
        uint256 forcedTokenAmount = 123;
        deal(address(token), address(launchHook), token.balanceOf(address(launchHook)) + forcedTokenAmount, false);
        address finalPositionRecipient = launchHook.bondingCurveConfig(key.toId()).finalPositionRecipient;
        uint256 burnedTokenBefore = token.balanceOf(address(0xdead));

        _swapThroughGraduation(key);
        _assertGraduated(token, key, curveTokenId, forcedTokenAmount, burnedTokenBefore, finalPositionRecipient);

        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function test_graduationRevertsWithUnsettledPositionManagerDelta() public {
        (MockERC20 token, PoolKey memory curveKey,) = _launch();
        swapRouter.swap{value: 1 ether}(
            curveKey,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        PoolKey memory sideKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(sideKey, TickMath.getSqrtPriceAtTick(0));
        vm.roll(block.number + feeModule.decayBlocks());

        SharedDeltaAttacker attacker = new SharedDeltaAttacker(POOL_MANAGER, POSITION_MANAGER);
        vm.expectRevert();
        attacker.attack{value: 20_000 ether}(curveKey, sideKey, 0.5 ether);

        assertEq(uint256(launchHook.bondingCurvePhase(curveKey.toId())), uint256(BondingCurvePhase.Active));
    }

    function _swapThroughGraduation(PoolKey memory key) private {
        int256 amountSpecified = -100_000 ether;
        BalanceDelta delta = swapRouter.swap{value: uint256(-amountSpecified)}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: amountSpecified, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(sqrtPriceX96, strategy.graduationSqrtPriceX96());
        assertLt(delta.amount0(), 0);
        assertGt(delta.amount0(), amountSpecified);
        assertGt(delta.amount1(), 0);
    }

    function _assertGraduated(
        MockERC20 token,
        PoolKey memory key,
        uint256 curveTokenId,
        uint256 forcedTokenAmount,
        uint256 burnedTokenBefore,
        address finalPositionRecipient
    ) private {
        uint256 finalTokenId = POSITION_MANAGER.nextTokenId() - 1;
        assertEq(token.balanceOf(address(launchHook)), 0);
        assertGe(token.balanceOf(address(0xdead)) - burnedTokenBefore, forcedTokenAmount);
        assertEq(uint256(launchHook.bondingCurvePhase(key.toId())), uint256(BondingCurvePhase.Graduated));
        vm.expectRevert();
        IERC721(address(POSITION_MANAGER)).ownerOf(curveTokenId);

        address finalRecipient = IERC721(address(POSITION_MANAGER)).ownerOf(finalTokenId);
        assertEq(finalRecipient, finalPositionRecipient);
        BuybackAndBurnPositionRecipient recipient = BuybackAndBurnPositionRecipient(payable(finalRecipient));
        assertEq(recipient.operator(), address(0));
        assertEq(recipient.timelockBlockNumber(), type(uint256).max);
        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(finalTokenId);
        assertEq(info.tickLower(), TickMath.minUsableTick(strategy.TICK_SPACING()));
        assertEq(info.tickUpper(), TickMath.maxUsableTick(strategy.TICK_SPACING()));
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    function _launch() private returns (MockERC20 token, PoolKey memory key, uint256 curveTokenId) {
        token = new MockERC20("Bonding Token", "BOND", strategy.TOTAL_SUPPLY(), address(this));
        token.approve(address(strategy), strategy.TOTAL_SUPPLY());
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(address(launchHook))
        });
        curveTokenId = POSITION_MANAGER.nextTokenId();
        strategy.initializeDistribution(address(token), strategy.TOTAL_SUPPLY(), bytes(""), bytes32(0));
        assertEq(launchHook.curveTokenId(key.toId()), curveTokenId);
    }

    receive() external payable {}
}
