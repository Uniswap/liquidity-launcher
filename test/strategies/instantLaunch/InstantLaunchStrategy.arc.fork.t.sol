// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Fork coverage against the live Arc (5042) v4 deployment from
// https://github.com/Uniswap/contracts/pull/144. Arc's PoolManager has no
// protocol fee controller, so InstantLaunch must tolerate a skipped fee update.

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {LiquidityLauncher} from "../../../src/LiquidityLauncher.sol";
import {Distribution} from "../../../src/types/Distribution.sol";
import {
    InstantLaunchStrategy,
    InstantLaunchConfig,
    LaunchPoolConfig
} from "../../../src/strategies/InstantLaunchStrategy.sol";
import {FeeSplitter} from "../../../src/periphery/FeeSplitter.sol";
import {BeneficiaryVault} from "../../../src/periphery/BeneficiaryVault.sol";
import {FeeSplit} from "../../../src/interfaces/IFeeSplitter.sol";

contract InstantLaunchStrategyArcForkTest is Test {
    using StateLibrary for IPoolManager;

    // https://github.com/Uniswap/contracts/pull/144
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0x6049c9a0e26405C0985f9E3685C87d0aE917f82B);
    IAllowanceTransfer internal constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    int24 internal constant INITIAL_TICK = 121_975;
    uint128 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant ARC_CHAIN_ID = 5042;

    LiquidityLauncher internal launcher;
    UERC20Factory internal factory;
    FeeSplitter internal feeSplitter;
    BeneficiaryVault internal beneficiaryVault;
    InstantLaunchStrategy internal strategy;
    address internal tokenJar = makeAddr("tokenJar");

    function setUp() public {
        string memory rpc = vm.envOr("ARC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, ARC_CHAIN_ID);
        // The live Arc PoolManager has no fee controller; this is the case the change covers.
        assertEq(POOL_MANAGER.protocolFeeController(), address(0));

        launcher = new LiquidityLauncher(PERMIT2);
        factory = new UERC20Factory();

        FeeSplit[] memory splits = new FeeSplit[](3);
        beneficiaryVault = new BeneficiaryVault(POSITION_MANAGER, Currency.wrap(address(0)), tokenJar, address(0xdead));
        splits[0] = FeeSplit({recipient: tokenJar, quoteBps: 8_000, tokenBps: 0, useCallback: false});
        splits[1] = FeeSplit({recipient: address(0xdead), quoteBps: 0, tokenBps: 8_000, useCallback: false});
        splits[2] =
            FeeSplit({recipient: address(beneficiaryVault), quoteBps: 2_000, tokenBps: 2_000, useCallback: true});
        feeSplitter = new FeeSplitter(POSITION_MANAGER, Currency.wrap(address(0)), splits);

        // Native quote + mainnet tick floor/cap; Arc-specific initial tick. Protocol fee controller
        // is unset on Arc — StrategyBase._handleFeeUpdate must tolerate that (asserted below).
        strategy = new InstantLaunchStrategy(
            address(launcher),
            POSITION_MANAGER,
            POOL_MANAGER,
            feeSplitter,
            beneficiaryVault,
            LaunchPoolConfig({
                quoteCurrency: Currency.wrap(address(0)),
                initialTick: INITIAL_TICK,
                minLaunchTick: -160_100,
                maxInitialTick: 251_325,
                minQuoteBlockerCost: 20_000_000 ether
            })
        );
    }

    function test_fork_instantLaunchCreatesPoolAgainstDeployedV4() public {
        address token =
            factory.getUERC20Address("ArcLaunch", "ARC", 18, address(launcher), launcher.getGraffiti(address(this)));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: strategy.LP_FEE(),
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        launcher.multicall(_buildCalls(token));

        (uint160 sqrtPriceX96, int24 tick,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(sqrtPriceX96, strategy.quote0InitialSqrtPriceX96());
        assertEq(tick, INITIAL_TICK);

        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        assertEq(info.tickLower(), strategy.minLaunchTick());
        assertEq(info.tickUpper(), INITIAL_TICK);
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), strategy.quote0PositionLiquidity());
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(feeSplitter));
        assertEq(beneficiaryVault.ownerOf(tokenId), address(this));
        assertEq(IERC20(token).balanceOf(address(launcher)), 0);
        assertEq(IERC20(token).balanceOf(address(strategy)), 0);
    }

    function _buildCalls(address token) internal view returns (bytes[] memory calls) {
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "arc instant launch",
            website: "https://pools.xyz",
            image: "https://pools.xyz/img.png",
            extraData: ""
        });
        Distribution memory distribution = Distribution({
            strategy: address(strategy),
            amount: TOTAL_SUPPLY,
            configData: abi.encode(InstantLaunchConfig({feeBeneficiary: address(this)}))
        });

        calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            LiquidityLauncher.createToken.selector,
            address(factory),
            "ArcLaunch",
            "ARC",
            uint8(18),
            TOTAL_SUPPLY,
            address(launcher),
            abi.encode(metadata)
        );
        calls[1] = abi.encodeWithSelector(LiquidityLauncher.distributeToken.selector, token, distribution, bytes32(0));
    }
}
