// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Proves the instant-launch strategy plugs into the canonical LiquidityLauncher flow:
// createToken(recipient = launcher) + distributeToken(strategy, ...) in a single multicall.
// Mirrors LiquidityLauncher.bondingCurve.t.sol without the hook handshake — the pool is hookless.

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {LiquidityLauncher} from "../src/LiquidityLauncher.sol";
import {Distribution} from "../src/types/Distribution.sol";
import {InstantLaunchStrategy, InstantLaunchConfig} from "../src/strategies/InstantLaunchStrategy.sol";
import {FeeSplitter} from "../src/periphery/FeeSplitter.sol";
import {BeneficiaryVault} from "../src/periphery/BeneficiaryVault.sol";
import {FeeSplit} from "../src/interfaces/IFeeSplitter.sol";

contract InstantLaunchStrategyLLIntegrationTest is Test, DeployPermit2 {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    int24 internal constant INITIAL_TICK = 121_975;
    uint128 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;

    LiquidityLauncher internal launcher;
    IAllowanceTransfer internal permit2;
    UERC20Factory internal factory;
    FeeSplitter internal feeSplitter;
    BeneficiaryVault internal beneficiaryVault;
    InstantLaunchStrategy internal strategy;
    address internal tokenJar = makeAddr("tokenJar");

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

        // The intended product configuration: ETH fees to the tokenJar, token fees burned,
        // both with a 20% creator share.
        FeeSplit[] memory splits = new FeeSplit[](3);
        beneficiaryVault = new BeneficiaryVault(POSITION_MANAGER, Currency.wrap(address(0)), tokenJar, address(0xdead));
        splits[0] = FeeSplit({recipient: tokenJar, quoteBps: 8_000, tokenBps: 0, useCallback: false});
        splits[1] = FeeSplit({recipient: address(0xdead), quoteBps: 0, tokenBps: 8_000, useCallback: false});
        splits[2] =
            FeeSplit({recipient: address(beneficiaryVault), quoteBps: 2_000, tokenBps: 2_000, useCallback: true});
        feeSplitter = new FeeSplitter(POSITION_MANAGER, Currency.wrap(address(0)), splits);

        // No hook handshake needed: the strategy's authorized launcher is the LiquidityLauncher itself.
        strategy = new InstantLaunchStrategy(
            address(launcher), POSITION_MANAGER, POOL_MANAGER, feeSplitter, beneficiaryVault, INITIAL_TICK
        );
    }

    function test_e2e_launchThroughLiquidityLauncher() public {
        address token =
            factory.getUERC20Address("QuickLaunch", "QL", 18, address(launcher), launcher.getGraffiti(address(this)));
        PoolKey memory key = _poolKeyFor(token);

        Distribution memory distribution = Distribution({
            strategy: address(strategy),
            amount: TOTAL_SUPPLY,
            configData: abi.encode(InstantLaunchConfig({feeBeneficiary: address(this)}))
        });

        uint256 tokenId = POSITION_MANAGER.nextTokenId();
        address recipient = address(feeSplitter);

        // The canonical fresh-mint flow, atomically: mint 1B into the launcher, then hand off to the strategy.
        launcher.multicall(_buildCalls(distribution));

        // The strategy ran end-to-end through the launcher and stood up the live pool.
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(sqrtPriceX96, strategy.initialSqrtPriceX96());
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), strategy.positionLiquidity());
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), recipient);
        // Launcher handed everything off; strategy retains nothing.
        assertEq(IERC20(token).balanceOf(address(launcher)), 0);
        assertEq(IERC20(token).balanceOf(address(strategy)), 0);
        assertEq(beneficiaryVault.ownerOf(tokenId), address(this));
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

        // Launched and bought in the launch block: the pool is live and the creator holds the tokens.
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(_poolKeyFor(token).toId());
        assertLt(sqrtPriceX96, strategy.initialSqrtPriceX96());
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
    ///      swap settles. Pool parameters are caller-independent, so the quote holds for the
    ///      Multicall3 run despite the different token address.
    function _quoteExactOutputBuy(PoolSwapTest swapRouter, uint256 buyAmount) internal returns (uint256 ethIn) {
        uint256 snapshot = vm.snapshotState();
        Distribution memory distribution = Distribution({
            strategy: address(strategy),
            amount: TOTAL_SUPPLY,
            configData: abi.encode(InstantLaunchConfig({feeBeneficiary: address(this)}))
        });
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
                    // The beneficiary is freely configured, so launch-and-buy through a generic
                    // aggregator pays the creator directly despite Multicall3 being the caller.
                    Distribution({
                        strategy: address(strategy),
                        amount: TOTAL_SUPPLY,
                        configData: abi.encode(InstantLaunchConfig({feeBeneficiary: creator}))
                    }),
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
            hooks: IHooks(address(0))
        });
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_e2e_launchThroughLiquidityLauncher_gas() public {
        Distribution memory distribution = Distribution({
            strategy: address(strategy),
            amount: TOTAL_SUPPLY,
            configData: abi.encode(InstantLaunchConfig({feeBeneficiary: address(this)}))
        });

        launcher.multicall(_buildCalls(distribution));
        vm.snapshotGasLastCall("InstantLaunch launch: LiquidityLauncher multicall");
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
