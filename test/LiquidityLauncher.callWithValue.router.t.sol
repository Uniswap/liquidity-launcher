// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {LiquidityLauncher} from "../src/LiquidityLauncher.sol";
import {Multicall} from "../src/Multicall.sol";
import {Distribution} from "../src/types/Distribution.sol";
import {InstantLaunchStrategy, InstantLaunchConfig} from "../src/strategies/InstantLaunchStrategy.sol";
import {FeeSplitter} from "../src/periphery/FeeSplitter.sol";
import {BeneficiaryVault} from "../src/periphery/BeneficiaryVault.sol";
import {FeeSplit} from "../src/interfaces/IFeeSplitter.sol";
import {IMulticall} from "../src/interfaces/IMulticall.sol";
import {IUniversalRouter} from "../src/interfaces/external/IUniversalRouter.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";

contract LiquidityLauncherCallWithValueRouterTest is Test, DeployPermit2 {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    int24 internal constant INITIAL_TICK = 121_980;
    uint128 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint24 internal constant LP_FEE = 2_500;
    int24 internal constant TICK_SPACING = 60;

    LiquidityLauncher internal launcher;
    UERC20Factory internal factory;
    InstantLaunchStrategy internal instantLaunch;
    MockUniversalRouter internal router;

    address internal creator = makeAddr("creator");

    function setUp() public {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );
        launcher = new LiquidityLauncher(IAllowanceTransfer(deployPermit2()));
        factory = new UERC20Factory();

        BeneficiaryVault beneficiaryVault = new BeneficiaryVault(POSITION_MANAGER, address(this), address(0xdead));
        FeeSplit[] memory splits = new FeeSplit[](1);
        splits[0] =
            FeeSplit({recipient: address(beneficiaryVault), nativeBps: 10_000, tokenBps: 10_000, useCallback: true});
        FeeSplitter feeSplitter = new FeeSplitter(POSITION_MANAGER, splits);

        instantLaunch = new InstantLaunchStrategy(
            address(launcher), POSITION_MANAGER, POOL_MANAGER, feeSplitter, beneficiaryVault, INITIAL_TICK
        );

        router = new MockUniversalRouter(POOL_MANAGER);
    }

    function test_launchAndBuy_throughCallWithValue() public {
        uint256 buyAmount = 1 ether;
        vm.deal(creator, buyAmount);

        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        vm.prank(creator);
        launcher.multicall{value: buyAmount}(_launchAndBuyCalls(token, key, buyAmount));

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertLt(sqrtPriceX96, instantLaunch.initialSqrtPriceX96(), "the buy did not move the price");
        assertGt(IERC20(token).balanceOf(creator), 0, "creator received no tokens");
        assertEq(address(launcher).balance, 0, "launcher kept native");
        assertEq(token, _predictToken(creator));
    }

    function test_launchAndBuy_sweepsUnspentNative() public {
        uint256 buyAmount = 1 ether;
        vm.deal(creator, buyAmount + 0.4 ether);

        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        bytes[] memory calls = new bytes[](3);
        calls[0] = _createTokenCall();
        calls[1] = _instantLaunchCall(token);
        calls[2] = abi.encodeCall(
            Multicall.callWithValue,
            (address(router), buyAmount + 0.4 ether, _routerExecuteCalldata(key, buyAmount))
        );

        vm.prank(creator);
        launcher.multicall{value: buyAmount + 0.4 ether}(calls);

        assertEq(creator.balance, 0.4 ether, "leftover native was not swept to the creator");
        assertEq(address(launcher).balance, 0);
        assertGt(IERC20(token).balanceOf(creator), 0);
    }

    function test_launchAndBuy_exactSpendRequired_whenBatchOverfundedWithoutRouteSweep() public {
        uint256 buyAmount = 1 ether;
        vm.deal(creator, buyAmount + 0.4 ether);

        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IMulticall.NativeNotSwept.selector, 0.4 ether));
        launcher.multicall{value: buyAmount + 0.4 ether}(_launchAndBuyCalls(token, key, buyAmount));
    }

    function _predictToken(address who) internal view returns (address) {
        return factory.getUERC20Address("QuickLaunch", "QL", 18, address(launcher), launcher.getGraffiti(who));
    }

    function _poolKeyFor(address token) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function _routerExecuteCalldata(PoolKey memory key, uint256 nativeIn) internal view returns (bytes memory) {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(key, nativeIn, address(0), uint256(0), creator);
        return abi.encodeCall(IUniversalRouter.execute, (hex"10", inputs, block.timestamp));
    }

    function _createTokenCall() internal view returns (bytes memory) {
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "quicklaunch token",
            website: "https://pools.xyz",
            image: "https://pools.xyz/img.png",
            xProofTweetId: 0
        });
        return abi.encodeWithSelector(
            LiquidityLauncher.createToken.selector,
            address(factory),
            "QuickLaunch",
            "QL",
            uint8(18),
            TOTAL_SUPPLY,
            address(launcher),
            abi.encode(metadata)
        );
    }

    function _instantLaunchCall(address token) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            LiquidityLauncher.distributeToken.selector,
            token,
            Distribution({
                strategy: address(instantLaunch),
                amount: TOTAL_SUPPLY,
                configData: abi.encode(InstantLaunchConfig({feeBeneficiary: creator}))
            }),
            bytes32(0)
        );
    }

    function _buyCall(PoolKey memory key, uint256 nativeAmount) internal view returns (bytes memory) {
        return abi.encodeCall(
            Multicall.callWithValue, (address(router), nativeAmount, _routerExecuteCalldata(key, nativeAmount))
        );
    }

    function _launchAndBuyCalls(address token, PoolKey memory key, uint256 nativeAmount)
        internal
        view
        returns (bytes[] memory calls)
    {
        calls = new bytes[](3);
        calls[0] = _createTokenCall();
        calls[1] = _instantLaunchCall(token);
        calls[2] = _buyCall(key, nativeAmount);
    }
}
