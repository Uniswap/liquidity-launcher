// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {DirectLaunchTestBase} from "../directLaunch/base/DirectLaunchTestBase.sol";
import {CanonicalLaunchStrategy} from "../../../src/strategies/CanonicalLaunchStrategy.sol";
import {BuybackAndBurnPositionRecipient} from "../../../src/periphery/BuybackAndBurnPositionRecipient.sol";
import {DutchDecayConfig} from "../../../src/periphery/modules/DutchDecayFeeModule.sol";
import {LaunchConfig} from "../../../src/interfaces/ILaunchHook.sol";
import {LiquidityLauncher} from "../../../src/LiquidityLauncher.sol";
import {Distribution} from "../../../src/types/Distribution.sol";
import {IAllowanceTransfer} from "../../../src/Permit2Forwarder.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract CanonicalLaunchStrategyE2ETest is DirectLaunchTestBase {
    using StateLibrary for IPoolManager;

    int24 internal constant INITIAL_TICK = 122_000;
    address internal constant BURN_ADDRESS = address(0xdead);

    LiquidityLauncher internal launcher;
    CanonicalLaunchStrategy internal canonicalStrategy;
    PoolSwapTest internal swapRouter;

    function setUp() public override {
        super.setUp();
        launcher = new LiquidityLauncher(IAllowanceTransfer(makeAddr("permit2")));
        canonicalStrategy = new CanonicalLaunchStrategy(
            address(launcher), strategy, address(launchHook), address(dutchModule), INITIAL_TICK
        );
        swapRouter = new PoolSwapTest(POOL_MANAGER);
    }

    function test_e2e_launchesCanonicalPool() public {
        uint256 launchBlock = block.number;
        (MockERC20 token, PoolKey memory key, uint256 tokenId) = _launch();

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertEq(
            token.balanceOf(address(POOL_MANAGER)) + token.balanceOf(BURN_ADDRESS), canonicalStrategy.TOTAL_SUPPLY()
        );
        assertLt(token.balanceOf(BURN_ADDRESS), 1 ether);
        assertEq(token.balanceOf(address(canonicalStrategy)), 0);

        address positionRecipient = IERC721(address(POSITION_MANAGER)).ownerOf(tokenId);
        BuybackAndBurnPositionRecipient recipient = BuybackAndBurnPositionRecipient(payable(positionRecipient));
        assertEq(recipient.token(), address(token));
        assertEq(recipient.currency(), address(0));
        assertEq(recipient.operator(), address(0));
        assertEq(recipient.timelockBlockNumber(), type(uint256).max);
        assertEq(recipient.minTokenBurnAmount(), canonicalStrategy.TOTAL_SUPPLY() / 2_000);

        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        assertEq(info.tickLower(), TickMath.minUsableTick(canonicalStrategy.TICK_SPACING()));
        assertEq(info.tickUpper(), INITIAL_TICK);

        LaunchConfig memory launchConfig = launchHook.launchConfig(key.toId());
        assertEq(launchConfig.swapStartBlock, launchBlock);
        assertEq(launchConfig.windowEndBlock, launchBlock + canonicalStrategy.DECAY_BLOCKS());
        assertEq(launchConfig.baseFee, 0);
        assertEq(launchConfig.module, address(dutchModule));
        DutchDecayConfig memory decay = abi.decode(launchConfig.moduleConfig, (DutchDecayConfig));
        assertEq(decay.startFee, canonicalStrategy.START_FEE());
        assertEq(decay.endFee, 0);
        assertEq(decay.decayBlocks, canonicalStrategy.DECAY_BLOCKS());
        assertTrue(decay.taxBothDirections);
    }

    function test_e2e_feeDecaysToZeroOverFiveBlocks() public {
        (, PoolKey memory key,) = _launch();
        uint256 launchBlock = block.number;

        for (uint256 elapsed; elapsed <= canonicalStrategy.DECAY_BLOCKS(); elapsed++) {
            vm.roll(launchBlock + elapsed);
            assertEq(
                _buy(key),
                canonicalStrategy.START_FEE() * (canonicalStrategy.DECAY_BLOCKS() - elapsed)
                    / canonicalStrategy.DECAY_BLOCKS()
            );
        }
    }

    function _launch() internal returns (MockERC20 token, PoolKey memory key, uint256 tokenId) {
        token = new MockERC20("Canonical Token", "CAN", canonicalStrategy.TOTAL_SUPPLY(), address(launcher));
        key = _poolKey(address(token));
        tokenId = _positionManager().nextTokenId();
        launcher.distributeToken(
            address(token),
            Distribution({
                strategy: address(canonicalStrategy),
                amount: uint128(canonicalStrategy.TOTAL_SUPPLY()),
                configData: bytes("")
            }),
            bytes32(0)
        );
    }

    function _poolKey(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: canonicalStrategy.TICK_SPACING(),
            hooks: IHooks(address(launchHook))
        });
    }

    function _buy(PoolKey memory key) internal returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapTopic = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == swapTopic) {
                (,,,,, fee) = abi.decode(logs[i - 1].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("Swap event not found");
    }
}
