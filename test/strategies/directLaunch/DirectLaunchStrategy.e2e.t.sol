// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// End-to-end coverage for the hookless direct launch. The launch position is permanently held by
// the singleton FeeSplitter, swaps are ungated from the first block, and fee collection runs
// permissionlessly through FeeSplitter.collectFees.

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {DirectLaunchStrategy, DirectLaunchConfig} from "../../../src/strategies/DirectLaunchStrategy.sol";
import {FeeSplitter} from "../../../src/periphery/FeeSplitter.sol";
import {BeneficiaryVault} from "../../../src/periphery/BeneficiaryVault.sol";
import {FeeSplit} from "../../../src/interfaces/IFeeSplitter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract DirectLaunchStrategyE2ETest is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    int24 internal constant INITIAL_TICK = 121_980;
    address internal constant BURN_ADDRESS = address(0xdead);

    address internal tokenJar = makeAddr("tokenJar");
    address internal creator = makeAddr("creator"); // the launch-configured fee beneficiary

    FeeSplitter internal feeSplitter;
    BeneficiaryVault internal beneficiaryVault;
    DirectLaunchStrategy internal strategy;
    PoolSwapTest internal swapRouter;

    function setUp() public {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );

        // The intended product configuration: ETH fees to the tokenJar, token fees burned,
        // both with a 20% creator share.
        FeeSplit[] memory splits = new FeeSplit[](3);
        beneficiaryVault = new BeneficiaryVault(POSITION_MANAGER, tokenJar, BURN_ADDRESS);
        splits[0] = FeeSplit({
            recipient: tokenJar, nativeBps: 8_000, tokenBps: 0, positionCallback: false, feesCallback: false
        });
        splits[1] = FeeSplit({
            recipient: BURN_ADDRESS, nativeBps: 0, tokenBps: 8_000, positionCallback: false, feesCallback: false
        });
        splits[2] = FeeSplit({
            recipient: address(beneficiaryVault),
            nativeBps: 2_000,
            tokenBps: 2_000,
            positionCallback: true,
            feesCallback: true
        });
        feeSplitter = new FeeSplitter(POSITION_MANAGER, splits);

        strategy = new DirectLaunchStrategy(
            address(this), POSITION_MANAGER, POOL_MANAGER, feeSplitter, address(beneficiaryVault), INITIAL_TICK
        );
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        vm.deal(address(this), 100_000 ether);
    }

    function test_launch_mintsSingleSidedPositionWithFullSupply() public {
        (MockERC20 token, PoolKey memory key, uint256 tokenId, address recipient) = _launch();

        // The pool opens at the configured price with the full supply on the token side of it.
        (uint160 sqrtPriceX96, int24 tick,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(sqrtPriceX96, strategy.initialSqrtPriceX96());
        assertEq(tick, INITIAL_TICK);

        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        assertEq(info.tickLower(), TickMath.minUsableTick(strategy.TICK_SPACING()));
        assertEq(info.tickUpper(), INITIAL_TICK);
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), strategy.positionLiquidity());
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), recipient);

        // Whole supply accounted for: everything is in the pool except burned rounding dust.
        assertEq(token.balanceOf(address(POOL_MANAGER)) + token.balanceOf(BURN_ADDRESS), strategy.TOTAL_SUPPLY());
        assertLt(token.balanceOf(BURN_ADDRESS), 1 ether);
        assertEq(token.balanceOf(address(strategy)), 0);

        // The custodian is the singleton fee splitter: no operator, no exit path.
        assertEq(recipient, address(feeSplitter));
    }

    function test_swapExactOutput_succeedsAtInitialBoundary() public {
        (MockERC20 token, PoolKey memory key,,) = _launch();
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

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_swapExactOutput_gas() public {
        (, PoolKey memory key,,) = _launch();

        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.snapshotGasLastCall("DirectLaunch swap: exact output");
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_swapExactInput_gas() public {
        (, PoolKey memory key,,) = _launch();

        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.snapshotGasLastCall("DirectLaunch swap: exact input");
    }

    function test_swapExactInput_largeBuyMovesPriceDownAndPoolKeepsTrading() public {
        (MockERC20 token, PoolKey memory key,,) = _launch();
        vm.deal(address(this), 101_000 ether);

        // A large buy has no terminal tick or phase change: the price walks down the single position
        // and the pool keeps trading in the same block.
        BalanceDelta delta = swapRouter.swap{value: 100_000 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(100_000 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        assertEq(delta.amount0(), -int256(100_000 ether));
        assertGt(delta.amount1(), 0);

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertLt(sqrtPriceX96, strategy.initialSqrtPriceX96());
        assertGt(sqrtPriceX96, TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(strategy.TICK_SPACING())));

        // Buys and sells both work immediately after — nothing gates the pool.
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -1_000 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function test_swap_sellAfterBuyReturnsEth() public {
        (MockERC20 token, PoolKey memory key,,) = _launch();

        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        uint256 tokenBalance = token.balanceOf(address(this));
        uint256 ethBefore = address(this).balance;
        token.approve(address(swapRouter), type(uint256).max);
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokenBalance),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        // The round trip returns ETH (less the two 1% LP fees) and all tokens are back in the pool.
        assertGt(delta.amount0(), 0);
        assertEq(delta.amount1(), -int256(tokenBalance));
        assertGt(address(this).balance, ethBefore);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_collectFees_distributesBothSidesToConfiguredRecipients() public {
        (MockERC20 token, PoolKey memory key, uint256 tokenId,) = _launch();

        // Accrue fees on both sides: a buy pays its LP fee in ETH (currency0), a sell in token (currency1).
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -100_000 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        uint128 liquidityBefore = POSITION_MANAGER.getPositionLiquidity(tokenId);
        (uint160 priceBefore,,,) = POOL_MANAGER.getSlot0(key.toId());
        uint256 burnedBefore = token.balanceOf(BURN_ADDRESS);

        // Harvesting is permissionless and free: any caller can trigger the distribution.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.prank(makeAddr("keeper"));
        feeSplitter.collectFees(tokenIds);

        // ETH fees split to the tokenJar and the beneficiary vault; token fees burn and vault.
        assertGt(tokenJar.balance, 0);
        assertGt(token.balanceOf(BURN_ADDRESS) - burnedBefore, 0);
        (uint256 nativeFees, uint256 tokenFees) = beneficiaryVault.fees(tokenId);
        assertGt(nativeFees, 0);
        assertGt(tokenFees, 0);
        // Nothing sticks to the splitter.
        assertEq(address(feeSplitter).balance, 0);
        assertEq(token.balanceOf(address(feeSplitter)), 0);
        // Collection moves fee revenue only: position liquidity and pool price are untouched.
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), liquidityBefore);
        (uint160 priceAfter,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);

        // The pool keeps trading normally after a collection.
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
    }

    function test_collectFees_secondCollectDistributesNothing() public {
        (, PoolKey memory key, uint256 tokenId,) = _launch();
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        feeSplitter.collectFees(tokenIds);

        // No trading in between, so a second collect has nothing to distribute.
        uint256 jarBefore = tokenJar.balance;
        uint256 creatorBefore = creator.balance;
        feeSplitter.collectFees(tokenIds);
        assertEq(tokenJar.balance, jarBefore);
        assertEq(creator.balance, creatorBefore);
    }

    function _launch() private returns (MockERC20 token, PoolKey memory key, uint256 tokenId, address recipient) {
        token = new MockERC20("Direct Token", "DIRECT", strategy.TOTAL_SUPPLY(), address(this));
        token.approve(address(strategy), strategy.TOTAL_SUPPLY());
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: strategy.LP_FEE(),
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        tokenId = POSITION_MANAGER.nextTokenId();
        recipient = address(feeSplitter);
        strategy.initializeDistribution(
            address(token),
            strategy.TOTAL_SUPPLY(),
            abi.encode(DirectLaunchConfig({feeBeneficiary: creator})),
            bytes32(0)
        );
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), recipient);
    }

    receive() external payable {}
}
