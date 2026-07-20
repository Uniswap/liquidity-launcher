// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Proves the bonding-curve strategy plugs into the canonical LiquidityLauncher flow:
// createToken(recipient = launcher) + distributeToken(strategy, ...) in a single multicall.

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {Preinstalls} from "@optimism/src/libraries/Preinstalls.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {LiquidityLauncher} from "../../src/LiquidityLauncher.sol";
import {Distribution} from "../../src/types/Distribution.sol";
import {BondingCurveLaunchStrategy} from "../../src/strategies/BondingCurveLaunchStrategy.sol";
import {BondingCurveLaunchHook} from "../../src/periphery/hooks/BondingCurveLaunchHook.sol";
import {IBondingCurveLaunchHook} from "../../src/interfaces/IBondingCurveLaunchHook.sol";
import {BondingCurvePhase} from "../../src/interfaces/IBondingCurveLaunchHook.sol";

contract BondingCurveLaunchStrategyLLIntegrationTest is Test, DeployPermit2 {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    int24 internal constant INITIAL_TICK = 122_000;
    int24 internal constant GRADUATION_TICK = 94_200;
    uint128 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;

    LiquidityLauncher internal launcher;
    IAllowanceTransfer internal permit2;
    UERC20Factory internal factory;
    BondingCurveLaunchHook internal hook;
    BondingCurveLaunchStrategy internal strategy;

    function setUp() public {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );
        permit2 = IAllowanceTransfer(deployPermit2());
        launcher = new LiquidityLauncher(permit2);
        factory = new UERC20Factory();

        // Deploy handshake: predict strategy addr, mine the hook bound to it, deploy strategy then hook.
        // The strategy's authorized launcher is the LiquidityLauncher itself.
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
            address(launcher),
            POSITION_MANAGER,
            POOL_MANAGER,
            IBondingCurveLaunchHook(hookAddress),
            INITIAL_TICK,
            GRADUATION_TICK
        );
        assertEq(address(strategy), predictedStrategy);
        hook = new BondingCurveLaunchHook{salt: salt}(POOL_MANAGER, POSITION_MANAGER, address(strategy));
        assertEq(address(hook), hookAddress);
    }

    function test_e2e_launchThroughLiquidityLauncher() public {
        address token =
            factory.getUERC20Address("QuickLaunch", "QL", 18, address(launcher), launcher.getGraffiti(address(this)));
        PoolKey memory key = _poolKeyFor(token);

        Distribution memory distribution =
            Distribution({strategy: address(strategy), amount: TOTAL_SUPPLY, configData: bytes("")});

        uint256 curveTokenId = POSITION_MANAGER.nextTokenId();

        // The canonical fresh-mint flow, atomically: mint 1B into the launcher, then hand off to the strategy.
        launcher.multicall(_buildCalls(distribution));

        // The strategy ran end-to-end through the launcher and stood up the live curve pool.
        assertEq(uint256(hook.bondingCurvePhase(key.toId())), uint256(BondingCurvePhase.Active));
        assertEq(hook.curveTokenId(key.toId()), curveTokenId);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(curveTokenId), address(hook));
        assertGe(IERC20(token).balanceOf(address(hook)), strategy.reserveSupply());
        // Launcher handed everything off; strategy retains nothing.
        assertEq(IERC20(token).balanceOf(address(launcher)), 0);
        assertEq(IERC20(token).balanceOf(address(strategy)), 0);
    }

    /// @notice A creator can launch and buy in one transaction today only through a generic
    ///         aggregator like Multicall3. This works, with two caveats the flow inherits:
    ///         the creator of record (graffiti) is Multicall3, not the EOA, and Multicall3 cannot
    ///         receive ETH, so the swap's value must be quoted exactly — any router refund reverts
    ///         the whole batch (see the overfunded companion test).
    function test_e2e_launchAndBuyInOneTransaction_throughMulticall3() public {
        vm.etch(Preinstalls.MultiCall3, Preinstalls.MultiCall3Code);
        PoolSwapTest swapRouter = new PoolSwapTest(POOL_MANAGER);
        address creator = makeAddr("creator");
        // Exact-output buy: the batch is static, so the token sweep amount must be known upfront.
        uint256 buyAmount = 1_000 ether;

        uint256 quotedEthIn = _quoteExactOutputBuy(swapRouter, buyAmount);
        vm.deal(creator, quotedEthIn);

        // Multicall3 is msg.sender to the launcher, so the token address derives from ITS graffiti.
        address token = factory.getUERC20Address(
            "QuickLaunch", "QL", 18, address(launcher), launcher.getGraffiti(Preinstalls.MultiCall3)
        );
        assertTrue(
            token != factory.getUERC20Address("QuickLaunch", "QL", 18, address(launcher), launcher.getGraffiti(creator))
        );

        IMulticall3.Call3Value[] memory calls = _launchAndBuyCalls(swapRouter, token, creator, buyAmount, quotedEthIn);
        vm.prank(creator);
        IMulticall3(Preinstalls.MultiCall3).aggregate3Value{value: quotedEthIn}(calls);

        // Launched and bought in the launch block: the pool is live and the creator holds the tokens,
        // having paid the full launch-block anti-snipe fee like any other buyer.
        PoolKey memory key = _poolKeyFor(token);
        assertEq(uint256(hook.bondingCurvePhase(key.toId())), uint256(BondingCurvePhase.Active));
        assertEq(IERC20(token).balanceOf(creator), buyAmount);
        assertEq(creator.balance, 0);
        assertEq(Preinstalls.MultiCall3.balance, 0);
        assertEq(IERC20(token).balanceOf(Preinstalls.MultiCall3), 0);
    }

    /// @notice Overfunding the swap leg by a single wei reverts the entire launch-and-buy batch:
    ///         the router refunds leftover ETH to its caller and Multicall3 rejects plain transfers.
    function test_e2e_launchAndBuyThroughMulticall3_revertsWhenSwapOverfunded() public {
        vm.etch(Preinstalls.MultiCall3, Preinstalls.MultiCall3Code);
        PoolSwapTest swapRouter = new PoolSwapTest(POOL_MANAGER);
        address creator = makeAddr("creator");
        uint256 buyAmount = 1_000 ether;

        uint256 overfundedEthIn = _quoteExactOutputBuy(swapRouter, buyAmount) + 1;
        vm.deal(creator, overfundedEthIn);
        address token = factory.getUERC20Address(
            "QuickLaunch", "QL", 18, address(launcher), launcher.getGraffiti(Preinstalls.MultiCall3)
        );

        IMulticall3.Call3Value[] memory calls =
            _launchAndBuyCalls(swapRouter, token, creator, buyAmount, overfundedEthIn);
        vm.prank(creator);
        vm.expectRevert("Multicall3: call failed");
        IMulticall3(Preinstalls.MultiCall3).aggregate3Value{value: overfundedEthIn}(calls);
    }

    /// @dev Dry-runs the launch + exact-output buy on a state snapshot to learn the exact ETH the
    ///      swap settles. Curve parameters and the fee schedule are caller-independent, so the quote
    ///      holds for the Multicall3 run despite the different token address.
    function _quoteExactOutputBuy(PoolSwapTest swapRouter, uint256 buyAmount) internal returns (uint256 ethIn) {
        uint256 snapshot = vm.snapshotState();
        Distribution memory distribution =
            Distribution({strategy: address(strategy), amount: TOTAL_SUPPLY, configData: bytes("")});
        launcher.multicall(_buildCalls(distribution));
        address token =
            factory.getUERC20Address("QuickLaunch", "QL", 18, address(launcher), launcher.getGraffiti(address(this)));

        vm.deal(address(this), 100 ether);
        BalanceDelta delta = swapRouter.swap{value: 100 ether}(
            _poolKeyFor(token),
            SwapParams({
                zeroForOne: true, amountSpecified: int256(buyAmount), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        ethIn = uint256(uint128(-delta.amount0()));
        vm.revertToState(snapshot);
    }

    function _launchAndBuyCalls(
        PoolSwapTest swapRouter,
        address token,
        address creator,
        uint256 buyAmount,
        uint256 swapValue
    ) internal view returns (IMulticall3.Call3Value[] memory calls) {
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "quicklaunch token",
            website: "https://pools.xyz",
            image: "https://pools.xyz/img.png",
            xProofTweetId: 0
        });
        calls = new IMulticall3.Call3Value[](4);
        calls[0] = IMulticall3.Call3Value({
            target: address(launcher),
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(
                LiquidityLauncher.createToken,
                (address(factory), "QuickLaunch", "QL", 18, TOTAL_SUPPLY, address(launcher), abi.encode(metadata))
            )
        });
        calls[1] = IMulticall3.Call3Value({
            target: address(launcher),
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(
                LiquidityLauncher.distributeToken,
                (
                    token,
                    Distribution({strategy: address(strategy), amount: TOTAL_SUPPLY, configData: bytes("")}),
                    bytes32(0)
                )
            )
        });
        calls[2] = IMulticall3.Call3Value({
            target: address(swapRouter),
            allowFailure: false,
            value: swapValue,
            callData: abi.encodeCall(
                PoolSwapTest.swap,
                (
                    _poolKeyFor(token),
                    SwapParams({
                        zeroForOne: true,
                        amountSpecified: int256(buyAmount),
                        sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                    }),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    bytes("")
                )
            )
        });
        // The router pays swap output to its caller (Multicall3), so the batch sweeps it to the EOA.
        calls[3] = IMulticall3.Call3Value({
            target: token,
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(IERC20.transfer, (creator, buyAmount))
        });
    }

    function _poolKeyFor(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: strategy.LP_FEE(),
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(address(hook))
        });
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_e2e_launchThroughLiquidityLauncher_gas() public {
        Distribution memory distribution =
            Distribution({strategy: address(strategy), amount: TOTAL_SUPPLY, configData: bytes("")});

        launcher.multicall(_buildCalls(distribution));
        vm.snapshotGasLastCall("BondingCurve launch: LiquidityLauncher multicall");
    }

    function _buildCalls(Distribution memory distribution) internal view returns (bytes[] memory calls) {
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "quicklaunch token",
            website: "https://pools.xyz",
            image: "https://pools.xyz/img.png",
            xProofTweetId: 0
        });
        address token =
            factory.getUERC20Address("QuickLaunch", "QL", 18, address(launcher), launcher.getGraffiti(address(this)));

        calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            LiquidityLauncher.createToken.selector,
            address(factory),
            "QuickLaunch",
            "QL",
            uint8(18),
            TOTAL_SUPPLY,
            address(launcher),
            abi.encode(metadata)
        );
        calls[1] = abi.encodeWithSelector(LiquidityLauncher.distributeToken.selector, token, distribution, bytes32(0));
    }

    receive() external payable {}
}
