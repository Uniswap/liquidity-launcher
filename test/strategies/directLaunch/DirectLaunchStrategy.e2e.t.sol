// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {DirectLaunchTestBase} from "./base/DirectLaunchTestBase.sol";
import {DirectLaunchParameters} from "../../../src/libraries/DirectLaunchParams.sol";
import {DutchDecayConfig} from "../../../src/periphery/modules/DutchDecayFeeModule.sol";
import {LiquidityLauncher} from "../../../src/LiquidityLauncher.sol";
import {ILiquidityLauncher} from "../../../src/interfaces/ILiquidityLauncher.sol";
import {Distribution} from "../../../src/types/Distribution.sol";
import {IAllowanceTransfer} from "../../../src/Permit2Forwarder.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice End-to-end tests: launch through the strategy (and launcher), then trade through the launch
/// window asserting the gate, the decaying fee, direction asymmetry, and the post-window base fee.
contract DirectLaunchStrategyE2ETest is DirectLaunchTestBase {
    using StateLibrary for IPoolManager;

    uint24 constant START_FEE = 500_000;
    uint24 constant END_FEE = 10_000;
    uint48 constant DECAY_BLOCKS = 50;
    uint48 constant WINDOW_BLOCKS = 100;

    PoolSwapTest swapRouter;
    uint48 swapStartBlock;
    uint48 windowEndBlock;

    /// @notice Receive native currency paid out by token sells
    receive() external payable {}

    function setUp() public override {
        super.setUp();
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        swapStartBlock = uint48(block.number + 10);
        windowEndBlock = swapStartBlock + WINDOW_BLOCKS;
    }

    /// @notice Launches a token against native currency behind the LaunchHook with a buy-side dutch decay
    function _launch() internal returns (MockERC20 token, PoolKey memory key) {
        token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params = _params(
            address(0),
            address(launchHook),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            _launchConfig(
                swapStartBlock,
                windowEndBlock,
                DutchDecayConfig({
                    startFee: START_FEE, endFee: END_FEE, decayBlocks: DECAY_BLOCKS, taxBothDirections: false
                })
            ),
            false
        );
        _launch(token, DEFAULT_SUPPLY, params);
        key = _poolKey(address(token), params);
    }

    /// @notice Buys the token (native in) with 1 ether exact input and returns the fee applied by the pool
    function _buy(PoolKey memory key) internal returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hex""
        );
        return _lastSwapFee();
    }

    /// @notice Sells `amount` of the token back into the pool and returns the fee applied
    function _sell(PoolKey memory key, MockERC20 token, uint256 amount) internal returns (uint24 fee) {
        token.approve(address(swapRouter), amount);
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amount), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hex""
        );
        return _lastSwapFee();
    }

    /// @notice Extracts the fee from the most recent PoolManager Swap event
    function _lastSwapFee() internal returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == swapTopic) {
                (,,,,, fee) = abi.decode(logs[i - 1].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("no Swap event recorded");
    }

    /// @notice Mirrors DutchDecayFeeModule's linear interpolation
    function _expectedFee(uint48 elapsed) internal pure returns (uint24) {
        if (elapsed >= DECAY_BLOCKS) return END_FEE;
        int256 delta = (int256(uint256(END_FEE)) - int256(uint256(START_FEE))) * int256(uint256(elapsed))
            / int256(uint256(DECAY_BLOCKS));
        return uint24(uint256(int256(uint256(START_FEE)) + delta));
    }

    function test_e2e_swapsRevertBeforeSwapStartBlock() public {
        (, PoolKey memory key) = _launch();

        vm.expectRevert();
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hex""
        );
    }

    function test_e2e_buyFeeDecaysAcrossTheWindowAndSettlesAtBaseFee() public {
        (MockERC20 token, PoolKey memory key) = _launch();
        uint256 tokenBalanceBefore = token.balanceOf(address(this));

        // launch block: full sniping tax
        vm.roll(swapStartBlock);
        assertEq(_buy(key), START_FEE);

        // mid-decay: linearly interpolated fee
        vm.roll(swapStartBlock + 25);
        assertEq(_buy(key), _expectedFee(25));

        // decay complete, window still open: end fee
        vm.roll(swapStartBlock + DECAY_BLOCKS);
        assertEq(_buy(key), END_FEE);

        // window over: pool trades at the configured base fee
        vm.roll(windowEndBlock);
        assertEq(_buy(key), BASE_FEE);

        // buys actually delivered tokens
        assertGt(token.balanceOf(address(this)), tokenBalanceBefore);
    }

    function test_e2e_sellsPayEndFeeDuringDecayWhenBuySideOnly() public {
        (MockERC20 token, PoolKey memory key) = _launch();

        vm.roll(swapStartBlock);
        _buy(key);

        // Still at the launch block: buys quote START_FEE but sells only pay END_FEE
        uint256 tokenBalance = token.balanceOf(address(this));
        assertGt(tokenBalance, 0);
        assertEq(_sell(key, token, tokenBalance / 2), END_FEE);
    }

    function test_e2e_fuzz_buyFeeMatchesModuleQuoteAtAnyWindowBlock(uint48 elapsed) public {
        elapsed = uint48(bound(elapsed, 0, WINDOW_BLOCKS - 1));
        (, PoolKey memory key) = _launch();

        vm.roll(swapStartBlock + elapsed);
        assertEq(_buy(key), _expectedFee(elapsed));
    }

    function test_gas_initializeDistributionAndWindowedSwaps() public {
        (, PoolKey memory key) = _launch();
        vm.snapshotGasLastCall("DirectLaunch: initializeDistribution with launch hook");

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.roll(swapStartBlock);
        swapRouter.swap{value: 1 ether}(key, params, settings, hex"");
        vm.snapshotGasLastCall("DirectLaunch: swap inside launch window (module fee)");

        vm.roll(windowEndBlock);
        swapRouter.swap{value: 1 ether}(key, params, settings, hex"");
        vm.snapshotGasLastCall("DirectLaunch: swap after launch window (base fee)");
    }

    function test_e2e_launchThroughLiquidityLauncher() public {
        LiquidityLauncher launcher = new LiquidityLauncher(IAllowanceTransfer(makeAddr("permit2")));
        MockERC20 token = new MockERC20("Test Token", "TT", DEFAULT_SUPPLY, address(launcher));

        DirectLaunchParameters memory params = _params(
            address(0), address(launchHook), LPFeeLibrary.DYNAMIC_FEE_FLAG, _gateOnlyLaunchConfig(swapStartBlock), false
        );
        PoolKey memory key = _poolKey(address(token), params);

        vm.expectEmit(true, true, false, true, address(launcher));
        emit ILiquidityLauncher.TokenDistributed(address(token), address(strategy), DEFAULT_SUPPLY);
        launcher.distributeToken(
            address(token),
            Distribution({strategy: address(strategy), amount: DEFAULT_SUPPLY, configData: abi.encode(params)}),
            bytes32(0)
        );

        // pool live, config registered, launcher fully drained
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(sqrtPriceX96, params.initialSqrtPriceX96);
        assertTrue(launchHook.isConfigured(key.toId()));
        assertEq(token.balanceOf(address(launcher)), 0);
        assertEq(token.allowance(address(launcher), address(strategy)), 0);

        // gated until the swap start block, then trading at the base fee
        vm.expectRevert();
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hex""
        );
        vm.roll(swapStartBlock);
        assertEq(_buy(key), BASE_FEE);
    }
}
