// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {BeneficiaryVault} from "../../src/periphery/BeneficiaryVault.sol";
import {PositionForwarder} from "../../src/periphery/PositionForwarder.sol";
import {PositionForwarderFactory} from "../../src/periphery/PositionForwarderFactory.sol";
import {IBeneficiaryVault} from "../../src/interfaces/IBeneficiaryVault.sol";
import {FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract PositionForwarderFactoryTest is Test {
    using CurrencyLibrary for Currency;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    address internal constant BURN_ADDRESS = address(0xdead);
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;

    PoolSwapTest internal swapRouter;
    WETH internal weth;
    address internal tokenJar = makeAddr("tokenJar");
    address internal beneficiary = makeAddr("beneficiary");

    FeeSplitter internal splitter;
    BeneficiaryVault internal vault;
    PositionForwarderFactory internal factory;

    function setUp() public {
        weth = new WETH();
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(weth)),
            address(POSITION_MANAGER)
        );
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        vm.deal(address(this), 10_000 ether);

        // The intended product configuration: ETH to the jar, token burned, 20% of both sides to the vault.
        vault = new BeneficiaryVault(POSITION_MANAGER, tokenJar, BURN_ADDRESS);
        FeeSplit[] memory entries = new FeeSplit[](3);
        entries[0] = FeeSplit({recipient: tokenJar, nativeBps: 8_000, tokenBps: 0, useCallback: false});
        entries[1] = FeeSplit({recipient: BURN_ADDRESS, nativeBps: 0, tokenBps: 8_000, useCallback: false});
        entries[2] = FeeSplit({recipient: address(vault), nativeBps: 2_000, tokenBps: 2_000, useCallback: true});
        splitter = new FeeSplitter(POSITION_MANAGER, entries);

        factory = new PositionForwarderFactory(POSITION_MANAGER, IBeneficiaryVault(address(vault)), address(splitter));
    }

    function _initPool(address token) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);
    }

    function _mintPosition(PoolKey memory key, address recipient, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId)
    {
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, lower, upper, liquidity, amount0, amount1, recipient, bytes(""));
        params[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency0, key.currency1, address(this));
        tokenId = POSITION_MANAGER.nextTokenId();
        IERC20(Currency.unwrap(key.currency1)).transfer(address(POSITION_MANAGER), amount1);
        POSITION_MANAGER.modifyLiquidities{value: amount0}(abi.encode(actions, params), block.timestamp);
    }

    function _accrueFees(PoolKey memory key) internal {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            bytes("")
        );
        IERC20(Currency.unwrap(key.currency1)).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            settings,
            bytes("")
        );
    }

    function _single(uint256 tokenId) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    /// @dev Mints a launch position straight to the forwarder's counterfactual address, as a migration would.
    function _launchInto(address forwarder) internal returns (MockERC20 token, PoolKey memory key, uint256 tokenId) {
        token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        key = _initPool(address(token));
        tokenId = _mintPosition(key, forwarder, 100 ether, 100 ether);
    }

    function test_predict_matchesDeployedAddress() public {
        address predicted = factory.predict(beneficiary);
        assertEq(predicted.code.length, 0, "forwarder exists before deployment");
        PositionForwarder forwarder = factory.deploy(beneficiary);
        assertEq(address(forwarder), predicted, "deployed at a different address");
        assertEq(forwarder.beneficiary(), beneficiary);
        assertEq(address(forwarder.vault()), address(vault));
        assertEq(forwarder.feeSplitter(), address(splitter));
    }

    function test_deploy_isIdempotent() public {
        address first = address(factory.deploy(beneficiary));
        address second = address(factory.deploy(beneficiary));
        assertEq(first, second, "second deploy returned a different address");
    }

    function test_deployAndFlush_registersBeneficiaryAndForwardsPosition() public {
        address forwarder = factory.predict(beneficiary);
        (MockERC20 token, PoolKey memory key, uint256 tokenId) = _launchInto(forwarder);

        // The position is minted while nothing is deployed at the forwarder address.
        assertEq(forwarder.code.length, 0, "forwarder deployed too early");
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), forwarder);

        factory.deployAndFlush(beneficiary, _single(tokenId));

        assertEq(vault.ownerOf(tokenId), beneficiary, "beneficiary NFT not minted");
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(splitter), "position not forwarded");

        // The full round trip: the splitter can now collect and the vault credits this position.
        _accrueFees(key);
        splitter.collectFees(_single(tokenId));
        (uint128 nativeAmount, uint128 tokenAmount) = vault.amounts(tokenId);
        assertGt(nativeAmount, 0, "no native credited");
        assertGt(tokenAmount, 0, "no token credited");
        assertGt(token.balanceOf(BURN_ADDRESS), 0, "burn share not paid");
        assertGt(tokenJar.balance, 0, "jar share not paid");
    }

    /// @notice One call settles a migrated launch end to end: deploy, register, forward, collect.
    function test_deployAndFlushCollect_settlesInOneCall() public {
        address forwarder = factory.predict(beneficiary);
        (MockERC20 token, PoolKey memory key, uint256 tokenId) = _launchInto(forwarder);
        // Fees accrue while the position still sits at the forwarder, unregistered and uncollected.
        _accrueFees(key);

        factory.deployAndFlushCollect(beneficiary, _single(tokenId));

        assertEq(vault.ownerOf(tokenId), beneficiary, "beneficiary NFT not minted");
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(splitter), "position not forwarded");
        (uint128 nativeAmount, uint128 tokenAmount) = vault.amounts(tokenId);
        assertGt(nativeAmount, 0, "no native credited");
        assertGt(tokenAmount, 0, "no token credited");
        assertGt(token.balanceOf(BURN_ADDRESS), 0, "burn share not paid");
        assertGt(tokenJar.balance, 0, "jar share not paid");

        // The credited fees are the beneficiary's to pull, with no further setup.
        vm.prank(beneficiary);
        vault.claim(tokenId, 0, 0);
        assertEq(beneficiary.balance, nativeAmount);
        assertEq(token.balanceOf(beneficiary), tokenAmount);
    }

    /// @notice Collecting a position that has accrued nothing is a no-op rather than a revert.
    function test_deployAndFlushCollect_withoutAccruedFees() public {
        address forwarder = factory.predict(beneficiary);
        (,, uint256 tokenId) = _launchInto(forwarder);

        factory.deployAndFlushCollect(beneficiary, _single(tokenId));

        assertEq(vault.ownerOf(tokenId), beneficiary);
        (uint128 nativeAmount, uint128 tokenAmount) = vault.amounts(tokenId);
        assertEq(nativeAmount, 0);
        assertEq(tokenAmount, 0);
    }

    function test_flush_handlesMultipleTokenIds() public {
        address forwarder = factory.predict(beneficiary);
        (, PoolKey memory key, uint256 first) = _launchInto(forwarder);
        uint256 second = _mintPosition(key, forwarder, 10 ether, 10 ether);

        uint256[] memory ids = new uint256[](2);
        ids[0] = first;
        ids[1] = second;
        factory.deployAndFlush(beneficiary, ids);

        assertEq(vault.ownerOf(first), beneficiary);
        assertEq(vault.ownerOf(second), beneficiary);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(first), address(splitter));
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(second), address(splitter));
    }

    function test_deployAndFlush_isPermissionless() public {
        address forwarder = factory.predict(beneficiary);
        (,, uint256 tokenId) = _launchInto(forwarder);

        vm.prank(makeAddr("keeper"));
        factory.deployAndFlush(beneficiary, _single(tokenId));

        assertEq(vault.ownerOf(tokenId), beneficiary, "keeper could not settle the launch");
    }

    function test_flush_revertsWhenForwarderDoesNotOwnPosition() public {
        MockERC20 token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        uint256 tokenId = _mintPosition(_initPool(address(token)), address(this), 100 ether, 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IBeneficiaryVault.NotPositionOwner.selector, tokenId, factory.predict(beneficiary))
        );
        factory.deployAndFlush(beneficiary, _single(tokenId));
    }

    function test_flush_revertsOnEmptyTokenIds() public {
        vm.expectRevert(PositionForwarder.NoTokenIds.selector);
        factory.deployAndFlush(beneficiary, new uint256[](0));
    }

    function test_deploy_revertsOnZeroBeneficiary() public {
        vm.expectRevert(PositionForwarder.ZeroBeneficiary.selector);
        factory.deploy(address(0));
    }

    function test_forwarder_isReusedAcrossLaunches() public {
        address forwarder = factory.predict(beneficiary);
        (,, uint256 firstLaunch) = _launchInto(forwarder);
        factory.deployAndFlush(beneficiary, _single(firstLaunch));

        // A second launch by the same beneficiary reuses the same forwarder, already deployed.
        (,, uint256 secondLaunch) = _launchInto(forwarder);
        factory.deployAndFlush(beneficiary, _single(secondLaunch));

        assertEq(vault.ownerOf(firstLaunch), beneficiary);
        assertEq(vault.ownerOf(secondLaunch), beneficiary);
        assertEq(factory.predict(beneficiary), forwarder, "forwarder address changed between launches");
    }

    receive() external payable {}
}
