// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// PROTOTYPE. Launch and buy in one transaction with no aggregator in front of the launcher: the buy rides
// the launcher's own multicall as a second `distributeToken`, whose strategy forwards a caller-supplied
// route to the Universal Router. The creator stays `msg.sender` for `createToken`, so the graffiti keeps
// naming them and the token lands at the address the client predicted.

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {LiquidityLauncher} from "../../src/LiquidityLauncher.sol";
import {Distribution} from "../../src/types/Distribution.sol";
import {InstantLaunchStrategy, InstantLaunchConfig} from "../../src/strategies/InstantLaunchStrategy.sol";
import {UniversalRouterStrategy, UniversalRouterConfig} from "../../src/strategies/UniversalRouterStrategy.sol";
import {FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {BeneficiaryVault} from "../../src/periphery/BeneficiaryVault.sol";
import {FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IUniversalRouter} from "../../src/interfaces/external/IUniversalRouter.sol";
import {MockUniversalRouter} from "../mocks/MockUniversalRouter.sol";
import {ReentrantRouter} from "../mocks/ReentrantRouter.sol";

contract UniversalRouterStrategyTest is Test, DeployPermit2 {
    using StateLibrary for IPoolManager;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    int24 internal constant INITIAL_TICK = 121_980;
    uint128 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint24 internal constant LP_FEE = 2_500;
    int24 internal constant TICK_SPACING = 60;

    LiquidityLauncher internal launcher;
    IAllowanceTransfer internal permit2;
    UERC20Factory internal factory;
    FeeSplitter internal feeSplitter;
    BeneficiaryVault internal beneficiaryVault;
    InstantLaunchStrategy internal instantLaunch;
    UniversalRouterStrategy internal routerStrategy;
    MockUniversalRouter internal router;

    address internal creator = makeAddr("creator");
    address internal attacker = makeAddr("attacker");

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

        beneficiaryVault = new BeneficiaryVault(POSITION_MANAGER, address(this), address(0xdead));
        FeeSplit[] memory splits = new FeeSplit[](1);
        splits[0] =
            FeeSplit({recipient: address(beneficiaryVault), nativeBps: 10_000, tokenBps: 10_000, useCallback: true});
        feeSplitter = new FeeSplitter(POSITION_MANAGER, splits);

        instantLaunch = new InstantLaunchStrategy(
            address(launcher), POSITION_MANAGER, POOL_MANAGER, feeSplitter, beneficiaryVault, INITIAL_TICK
        );

        router = new MockUniversalRouter(POOL_MANAGER);
        routerStrategy = new UniversalRouterStrategy(address(launcher));
    }

    /// @notice The point of the design: one transaction, no aggregator, EOA stays the creator of record.
    function test_launchAndBuy_throughTheLauncherMulticall() public {
        uint256 buyAmount = 1 ether;
        vm.deal(creator, buyAmount);

        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        vm.prank(creator);
        launcher.multicall{value: buyAmount}(_launchAndBuyCalls(token, key, buyAmount, 0));

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertLt(sqrtPriceX96, instantLaunch.initialSqrtPriceX96(), "the buy did not move the price");
        assertGt(IERC20(token).balanceOf(creator), 0, "creator received no tokens");
        // Nothing is left anywhere in the path.
        assertEq(address(launcher).balance, 0, "launcher kept native");
        assertEq(address(routerStrategy).balance, 0, "strategy kept native");
        assertEq(IERC20(token).balanceOf(address(routerStrategy)), 0, "strategy kept tokens");
        // Still the EOA's graffiti, which is what an aggregator in front of the launcher would cost.
        assertEq(token, _predictToken(creator));
        assertTrue(token != _predictToken(address(router)));
    }

    /// @notice The route's output is credited to the router's caller — this strategy — so it must sweep.
    function test_buy_sweepsWhatTheRouteLeavesBehind() public {
        uint256 buyAmount = 1 ether;
        // Overfund by 0.4: the mock spends only what the route asks for, as a real route with SWEEP would.
        vm.deal(creator, buyAmount + 0.4 ether);
        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        bytes[] memory calls = new bytes[](3);
        calls[0] = _createTokenCall();
        calls[1] = _instantLaunchCall(token);
        // Forward 1.4 but give the route only 1 to spend, so the route sweeps 0.4 to its recipient.
        calls[2] = abi.encodeCall(
            LiquidityLauncher.distributeWithNative,
            (
                address(routerStrategy),
                abi.encode(_route(key, buyAmount, address(0), 0)),
                bytes32(0),
                buyAmount + 0.4 ether
            )
        );

        vm.prank(creator);
        launcher.multicall{value: buyAmount + 0.4 ether}(calls);

        // The unspent 0.4 came back to the creator rather than sticking in the strategy or the router.
        assertEq(creator.balance, 0.4 ether, "leftover native was not swept to the creator");
        assertEq(address(routerStrategy).balance, 0);
        assertGt(IERC20(token).balanceOf(creator), 0);
    }

    /// @notice One payment cannot fund two native hand-offs: the second has nothing left to send.
    function test_twoNativeDistributions_onOnePayment_reverts() public {
        uint256 buyAmount = 1 ether;
        vm.deal(creator, buyAmount);
        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        bytes[] memory calls = new bytes[](4);
        calls[0] = _createTokenCall();
        calls[1] = _instantLaunchCall(token);
        calls[2] = _buyCall(token, key, buyAmount, 0);
        calls[3] = _buyCall(token, key, buyAmount, 0);

        vm.prank(creator);
        vm.expectRevert();
        launcher.multicall{value: buyAmount}(calls);
    }

    /// @notice Halves of the same payment both go through, so the accounting is exact, not just safe.
    function test_twoNativeDistributions_withinOnePayment_succeed() public {
        uint256 buyAmount = 1 ether;
        vm.deal(creator, buyAmount);
        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        bytes[] memory calls = new bytes[](4);
        calls[0] = _createTokenCall();
        calls[1] = _instantLaunchCall(token);
        calls[2] = _buyCall(token, key, buyAmount / 2, 0);
        calls[3] = _buyCall(token, key, buyAmount / 2, 0);

        vm.prank(creator);
        launcher.multicall{value: buyAmount}(calls);

        assertGt(IERC20(token).balanceOf(creator), 0);
        assertEq(address(launcher).balance, 0);
    }

    /// @notice Paying for the buy with an ERC-20 the creator already holds, rather than native.
    function test_buy_fundedWithAnErc20() public {
        uint128 inputAmount = 500 ether;
        address inputToken = address(new MockPayToken(creator, inputAmount));

        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        vm.startPrank(creator);
        IERC20(inputToken).approve(address(permit2), inputAmount);
        permit2.approve(inputToken, address(launcher), inputAmount, uint48(block.timestamp + 1));

        bytes[] memory calls = new bytes[](4);
        calls[0] = _createTokenCall();
        calls[1] = _instantLaunchCall(token);
        // Pull the input token into the launcher, then hand it to the route as the buy's funding.
        calls[2] = abi.encodeCall(LiquidityLauncher.depositToken, (inputToken, inputAmount));
        calls[3] = abi.encodeWithSelector(
            LiquidityLauncher.distributeToken.selector,
            inputToken,
            Distribution({
                strategy: address(routerStrategy),
                amount: inputAmount,
                configData: abi.encode(_route(key, 0, inputToken, inputAmount))
            }),
            bytes32(0)
        );
        launcher.multicall(calls);
        vm.stopPrank();

        // The input reached the router straight from the launcher's allowance, so the creator never had to
        // approve the router itself — which is what makes paying in another token possible here.
        assertEq(IERC20(inputToken).balanceOf(address(router)), inputAmount / 2, "router was not funded");
        assertEq(IERC20(inputToken).balanceOf(address(launcher)), 0, "launcher kept the input token");
        assertEq(IERC20(inputToken).balanceOf(address(routerStrategy)), 0, "strategy kept the input token");
        assertEq(IERC20(inputToken).allowance(creator, address(router)), 0, "creator approved the router");
        // What the route did not use came back to the creator, which is all this strategy owes on this path.
        assertEq(IERC20(inputToken).balanceOf(creator), inputAmount / 2, "unused input was not returned");
    }

    /// @notice Overfunding a batch is a caller error that strands the excess in the launcher: there is no
    ///         refund path, so the amounts forwarded must add up to the value sent.
    function test_overfundedBatch_strandsTheExcess() public {
        uint256 buyAmount = 1 ether;
        vm.deal(creator, buyAmount + 0.4 ether);
        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        vm.prank(creator);
        launcher.multicall{value: buyAmount + 0.4 ether}(_launchAndBuyCalls(token, key, buyAmount, 0));

        assertEq(address(launcher).balance, 0.4 ether, "excess did not stay in the launcher");
        assertEq(creator.balance, 0, "creator was refunded");
    }

    /// @notice Native already sitting in the launcher, forced in or stranded by an earlier caller, does not
    ///         affect a batch: nothing reads the launcher's balance.
    function test_strayNative_doesNotAffectABatch() public {
        vm.deal(address(launcher), 1 wei);

        bytes[] memory calls = new bytes[](1);
        calls[0] = _createTokenCall();

        vm.prank(creator);
        launcher.multicall(calls);

        assertEq(address(launcher).balance, 1 wei, "stray native was consumed");
    }

    /// @notice Regression for the reentrancy finding: a router that reenters to divert native earmarked for a
    ///         later hand-off breaks that hand-off, so the whole batch reverts and the theft gains nothing.
    function test_reentrantRouterCannotDivertEarmarkedNative() public {
        DivertingRouter diverter = new DivertingRouter(launcher, address(routerStrategy), attacker);
        address token = _predictToken(creator);
        PoolKey memory key = _poolKeyFor(token);

        UniversalRouterConfig memory divertConfig = UniversalRouterConfig({
            router: diverter, recipient: creator, route: abi.encode(bytes(""), new bytes[](0), block.timestamp)
        });

        // 1 ether to the diverting route, 1 ether earmarked for a second hand-off.
        bytes[] memory calls = new bytes[](4);
        calls[0] = _createTokenCall();
        calls[1] = _instantLaunchCall(token);
        calls[2] = abi.encodeCall(
            LiquidityLauncher.distributeWithNative,
            (address(routerStrategy), abi.encode(divertConfig), bytes32(0), 1 ether)
        );
        calls[3] = _buyCall(token, key, 1 ether, 0);

        vm.deal(creator, 2 ether);
        vm.prank(creator);
        vm.expectRevert();
        launcher.multicall{value: 2 ether}(calls);

        assertEq(attacker.balance, 0, "attacker kept diverted native");
    }

    function test_initializeDistribution_onlyLauncher() public {
        vm.expectRevert(UniversalRouterStrategy.OnlyLauncher.selector);
        routerStrategy.initializeDistribution(address(0), 0, "", bytes32(0));
    }

    /// @notice The native entry point is the only way native reaches the strategy, and only the launcher may
    ///         use it — so the strategy can never sit on a balance between calls.
    function test_initializeWithNative_onlyLauncher() public {
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(UniversalRouterStrategy.OnlyLauncher.selector);
        routerStrategy.initializeWithNative{value: 1 ether}("", bytes32(0));

        assertEq(address(routerStrategy).balance, 0);
    }

    /// @notice LL → strategy → router → LL → strategy must revert on the nested strategy entry.
    function test_reentrantRouterThroughLauncher_reverts() public {
        ReentrantRouter reentrantRouter = new ReentrantRouter(launcher, address(routerStrategy));

        UniversalRouterConfig memory config = UniversalRouterConfig({
            router: reentrantRouter, recipient: creator, route: abi.encode(bytes(""), new bytes[](0), block.timestamp)
        });

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            LiquidityLauncher.distributeWithNative, (address(routerStrategy), abi.encode(config), bytes32(0), 1 ether)
        );

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
        launcher.multicall{value: 1 ether}(calls);
    }

    /// @notice A router with no code reverts instead of consuming the forwarded native. The typed `execute`
    ///         call carries solc's code check; a low-level call would have sent the ether into the void.
    function test_routerWithoutCode_revertsAndKeepsNative() public {
        UniversalRouterConfig memory config = UniversalRouterConfig({
            router: IUniversalRouter(address(0)),
            recipient: creator,
            route: abi.encode(hex"10", new bytes[](0), block.timestamp)
        });

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            LiquidityLauncher.distributeWithNative, (address(routerStrategy), abi.encode(config), bytes32(0), 1 ether)
        );

        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert();
        launcher.multicall{value: 1 ether}(calls);

        assertEq(creator.balance, 1 ether, "native was consumed by a codeless router");
        assertEq(address(0).balance, 0, "native was burned");
    }

    // ── helpers ──

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

    /// @notice Stands in for a Universal Router route: buy `key`'s token, paying `nativeIn` or `erc20In`.
    function _route(PoolKey memory key, uint256 nativeIn, address payToken, uint256 payAmount)
        internal
        view
        returns (UniversalRouterConfig memory)
    {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(key, nativeIn, payToken, payAmount, creator);
        // hex"10" is V4_SWAP
        return UniversalRouterConfig({
            router: router, recipient: creator, route: abi.encode(hex"10", inputs, block.timestamp)
        });
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

    function _buyCall(address token, PoolKey memory key, uint256 nativeAmount, uint256 erc20Amount)
        internal
        view
        returns (bytes memory)
    {
        erc20Amount; // the native entry point has no token leg
        return abi.encodeCall(
            LiquidityLauncher.distributeWithNative,
            (address(routerStrategy), abi.encode(_route(key, nativeAmount, address(0), 0)), bytes32(0), nativeAmount)
        );
    }

    function _launchAndBuyCalls(address token, PoolKey memory key, uint256 nativeAmount, uint256 erc20Amount)
        internal
        view
        returns (bytes[] memory calls)
    {
        calls = new bytes[](3);
        calls[0] = _createTokenCall();
        calls[1] = _instantLaunchCall(token);
        calls[2] = _buyCall(token, key, nativeAmount, erc20Amount);
    }
}

/// @notice An ERC-20 the creator already holds, used to fund a buy without native.
contract MockPayToken {
    string public name = "Pay";
    string public symbol = "PAY";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address holder, uint256 amount) {
        balanceOf[holder] = amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != msg.sender) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Router that tries to divert the launcher's un-forwarded native to a third party mid-batch.
contract DivertingRouter is IUniversalRouter {
    LiquidityLauncher immutable launcher;
    address immutable strategy;
    address immutable attacker;

    constructor(LiquidityLauncher _launcher, address _strategy, address _attacker) {
        launcher = _launcher;
        strategy = _strategy;
        attacker = _attacker;
    }

    function execute(bytes calldata, bytes[] calldata, uint256) external payable override {
        launcher.distributeWithNative(attacker, abi.encode(uint256(0)), bytes32(0), address(launcher).balance);
    }
}
