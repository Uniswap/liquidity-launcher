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
import {IFeeSplitter, FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeesCallback} from "../mocks/MockFeesCallback.sol";

contract MockPosmSweeperFeeRecipient {
    IPositionManager internal immutable posm;
    Currency[] internal currencies;
    uint256 public notifiedNative;
    uint256 public notifiedToken;
    uint256 public sweepAttempts;

    constructor(IPositionManager _posm) {
        posm = _posm;
    }

    function addSweepCurrency(Currency currency) external {
        currencies.push(currency);
    }

    function onAmountsReceived(uint256, uint256 currency0Amount, uint256 currency1Amount) external {
        notifiedNative += currency0Amount;
        notifiedToken += currency1Amount;
        bytes memory actions = new bytes(currencies.length);
        bytes[] memory params = new bytes[](currencies.length);
        for (uint256 i; i < currencies.length; i++) {
            actions[i] = bytes1(uint8(Actions.SWEEP));
            params[i] = abi.encode(currencies[i], address(this));
        }
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        sweepAttempts++;
    }

    receive() external payable {}
}

contract FeeSplitterTest is Test {
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
    address internal creator = makeAddr("creator");
    BeneficiaryVault internal beneficiaryVault;

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
    }

    function _split(address recipient, uint16 nativeBps, uint16 tokenBps, bool useCallback)
        internal
        pure
        returns (FeeSplit memory)
    {
        return FeeSplit(recipient, nativeBps, tokenBps, useCallback);
    }

    function _splits(FeeSplit memory split_) internal pure returns (FeeSplit[] memory out) {
        out = new FeeSplit[](1);
        out[0] = split_;
    }

    function _defaultSplitter() internal returns (FeeSplitter splitter) {
        beneficiaryVault = new BeneficiaryVault(POSITION_MANAGER, tokenJar, BURN_ADDRESS);
        FeeSplit[] memory entries = new FeeSplit[](3);
        entries[0] = _split(tokenJar, 8_000, 0, false);
        entries[1] = _split(BURN_ADDRESS, 0, 8_000, false);
        entries[2] = _split(address(beneficiaryVault), 2_000, 2_000, true);
        splitter = new FeeSplitter(POSITION_MANAGER, entries);
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
        uint256 value;
        if (key.currency0.isAddressZero()) value = amount0;
        else IERC20(Currency.unwrap(key.currency0)).transfer(address(POSITION_MANAGER), amount0);
        IERC20(Currency.unwrap(key.currency1)).transfer(address(POSITION_MANAGER), amount1);
        POSITION_MANAGER.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp);
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

    function _positionWithFees(FeeSplitter splitter, bool registered)
        internal
        returns (MockERC20 token, PoolKey memory key, uint256 tokenId)
    {
        token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        key = _initPool(address(token));
        tokenId = _mintPosition(key, address(this), 100 ether, 100 ether);
        // Registration happens directly with the vault while this test contract still owns the position.
        if (registered) beneficiaryVault.registerBeneficiary(tokenId, creator);
        IERC721(address(POSITION_MANAGER)).transferFrom(address(this), address(splitter), tokenId);
        _accrueFees(key);
    }

    function _single(uint256 tokenId) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    function test_constructor_storesConfiguration() public {
        FeeSplitter splitter = _defaultSplitter();
        FeeSplit[] memory entries = splitter.getSplits();
        assertEq(entries.length, 3);
        assertEq(entries[0].recipient, tokenJar);
        assertEq(entries[0].nativeBps, 8_000);
        assertEq(entries[0].tokenBps, 0);
        assertFalse(entries[0].useCallback);
        assertEq(entries[2].recipient, address(beneficiaryVault));
        assertEq(entries[2].nativeBps, 2_000);
        assertEq(entries[2].tokenBps, 2_000);
        assertTrue(entries[2].useCallback);
    }

    function test_constructor_revertsOnZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidRecipient.selector, address(0)));
        new FeeSplitter(POSITION_MANAGER, _splits(_split(address(0), 10_000, 10_000, false)));
    }

    function test_constructor_revertsOnSelfRecipient() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidRecipient.selector, predicted));
        new FeeSplitter(POSITION_MANAGER, _splits(_split(predicted, 10_000, 10_000, false)));
    }

    function test_constructor_revertsOnCallbackRecipientWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.CallbackRecipientNotContract.selector, creator));
        new FeeSplitter(POSITION_MANAGER, _splits(_split(creator, 10_000, 10_000, true)));
    }

    function test_constructor_revertsOnNoSplits() public {
        vm.expectRevert(IFeeSplitter.NoSplits.selector);
        new FeeSplitter(POSITION_MANAGER, new FeeSplit[](0));
    }

    function test_constructor_revertsOnBothZeroBps() public {
        FeeSplit[] memory entries = new FeeSplit[](2);
        entries[0] = _split(tokenJar, 10_000, 10_000, false);
        entries[1] = _split(creator, 0, 0, false);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.ZeroSplitBps.selector, creator));
        new FeeSplitter(POSITION_MANAGER, entries);
    }

    function test_constructor_revertsOnDuplicateRecipient() public {
        FeeSplit[] memory entries = new FeeSplit[](2);
        entries[0] = _split(tokenJar, 5_000, 5_000, false);
        entries[1] = _split(tokenJar, 5_000, 5_000, false);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.DuplicateRecipient.selector, tokenJar));
        new FeeSplitter(POSITION_MANAGER, entries);
    }

    function test_constructor_revertsOnInvalidNativeTotal() public {
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidSplitTotal.selector, 9_999));
        new FeeSplitter(POSITION_MANAGER, _splits(_split(tokenJar, 9_999, 10_000, false)));
    }

    function test_constructor_revertsOnInvalidTokenTotal() public {
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidSplitTotal.selector, 9_999));
        new FeeSplitter(POSITION_MANAGER, _splits(_split(tokenJar, 10_000, 9_999, false)));
    }

    function test_onERC721Received_ignoresTransferData() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("T", "T", 1_000 ether, address(this));
        uint256 tokenId = _mintPosition(_initPool(address(token)), address(this), 100 ether, 100 ether);
        // The splitter learns nothing at deposit: arbitrary data is accepted and ignored, and no
        // registration happens — that is a direct interaction with the vault.
        IERC721(address(POSITION_MANAGER))
            .safeTransferFrom(address(this), address(splitter), tokenId, abi.encode(creator, uint256(42)));
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(splitter));
        assertEq(beneficiaryVault.balanceOf(creator), 0);
    }

    function test_onERC721Received_revertsForNonPositionManagerNFT() public {
        FeeSplitter splitter = _defaultSplitter();
        address impostor = makeAddr("impostor");
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.NotPositionManager.selector, impostor));
        splitter.onERC721Received(address(this), address(this), 1, bytes(""));
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_collectFees_distributesBothSidesAndCreditsVault() public {
        FeeSplitter splitter = _defaultSplitter();
        (MockERC20 token,, uint256 tokenId) = _positionWithFees(splitter, true);
        uint256 jarBefore = tokenJar.balance;
        uint256 burnBefore = token.balanceOf(BURN_ADDRESS);
        splitter.collectFees(_single(tokenId));
        vm.snapshotGasLastCall("FeeSplitter.collectFees");
        (uint256 nativeFees, uint256 tokenFees) = beneficiaryVault.amounts(tokenId);
        assertGt(tokenJar.balance - jarBefore, 0);
        assertGt(token.balanceOf(BURN_ADDRESS) - burnBefore, 0);
        assertGt(nativeFees, 0);
        assertGt(tokenFees, 0);
        assertEq(beneficiaryVault.ownerOf(tokenId), creator);
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_collectFees_revertsOnEmptyTokenIds() public {
        FeeSplitter splitter = _defaultSplitter();
        vm.expectRevert(IFeeSplitter.NoTokenIds.selector);
        splitter.collectFees(new uint256[](0));
    }

    function test_collectFees_notifiesFlaggedRecipientOnceWithBothAmounts() public {
        MockFeesCallback callback = new MockFeesCallback();
        FeeSplitter splitter =
            new FeeSplitter(POSITION_MANAGER, _splits(_split(address(callback), 10_000, 10_000, true)));
        (MockERC20 token,, uint256 tokenId) = _positionWithFees(splitter, false);
        splitter.collectFees(_single(tokenId));
        assertEq(callback.feesCalls(), 1);
        assertEq(callback.lastFeesTokenId(), tokenId);
        assertEq(callback.lastCurrency0Amount(), address(callback).balance);
        assertEq(callback.lastCurrency1Amount(), token.balanceOf(address(callback)));
        assertGt(callback.lastCurrency0Amount(), 0);
        assertGt(callback.lastCurrency1Amount(), 0);
    }

    function test_collectFees_swallowsRevertingFeesCallback() public {
        MockFeesCallback callback = new MockFeesCallback();
        callback.setRevertFees(true);
        FeeSplitter splitter =
            new FeeSplitter(POSITION_MANAGER, _splits(_split(address(callback), 10_000, 10_000, true)));
        (MockERC20 token,, uint256 tokenId) = _positionWithFees(splitter, false);
        splitter.collectFees(_single(tokenId));
        assertGt(address(callback).balance, 0);
        assertGt(token.balanceOf(address(callback)), 0);
        assertEq(address(splitter).balance, 0);
    }

    function test_collectFees_forceSendsNativeAndStillAttemptsCallback() public {
        MockFeesCallback callback = new MockFeesCallback();
        callback.setRejectNative(true);
        FeeSplit[] memory entries = new FeeSplit[](2);
        entries[0] = _split(address(callback), 10_000, 0, true);
        entries[1] = _split(BURN_ADDRESS, 0, 10_000, false);
        FeeSplitter splitter = new FeeSplitter(POSITION_MANAGER, entries);
        (,, uint256 tokenId) = _positionWithFees(splitter, false);
        splitter.collectFees(_single(tokenId));
        assertGt(address(callback).balance, 0);
        assertEq(callback.feesCalls(), 1);
        assertGt(callback.lastCurrency0Amount(), 0);
        assertEq(callback.lastCurrency1Amount(), 0);
    }

    function test_collectFees_flushesDonations() public {
        FeeSplitter splitter = _defaultSplitter();
        (MockERC20 token,, uint256 tokenId) = _positionWithFees(splitter, true);
        vm.deal(address(splitter), 5 ether);
        token.transfer(address(splitter), 7 ether);
        splitter.collectFees(_single(tokenId));
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_increaseLiquidity_usesPositionManagerBalancesAndRefundsExcess() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("T", "T", 1_000_000 ether, address(this));
        uint256 tokenId = _mintPosition(_initPool(address(token)), address(splitter), 100 ether, 100 ether);
        uint128 beforeLiquidity = POSITION_MANAGER.getPositionLiquidity(tokenId);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(POSITION_MANAGER), 10 ether);
        token.transfer(address(POSITION_MANAGER), 10 ether);
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));
        splitter.increaseLiquidity(tokenId, 1 ether, 10 ether, 10 ether, bytes(""));
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), beforeLiquidity + 1 ether);
        assertGt(address(this).balance, ethBefore);
        assertGt(token.balanceOf(address(this)), tokenBefore);
        assertEq(weth.balanceOf(address(POSITION_MANAGER)), 0);
        assertEq(token.balanceOf(address(POSITION_MANAGER)), 0);
    }

    function test_increaseLiquidity_revertsOnUncollectedFees() public {
        FeeSplitter splitter = _defaultSplitter();
        (MockERC20 token,, uint256 tokenId) = _positionWithFees(splitter, true);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(POSITION_MANAGER), 10 ether);
        token.transfer(address(POSITION_MANAGER), 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.UncollectedFees.selector, tokenId));
        splitter.increaseLiquidity(tokenId, 1 ether, 10 ether, 10 ether, bytes(""));
    }

    function test_increaseLiquidity_succeedsAfterCollect() public {
        FeeSplitter splitter = _defaultSplitter();
        (MockERC20 token,, uint256 tokenId) = _positionWithFees(splitter, true);
        splitter.collectFees(_single(tokenId));
        uint128 beforeLiquidity = POSITION_MANAGER.getPositionLiquidity(tokenId);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(POSITION_MANAGER), 10 ether);
        token.transfer(address(POSITION_MANAGER), 10 ether);
        splitter.increaseLiquidity(tokenId, 1 ether, 10 ether, 10 ether, bytes(""));
        (uint256 nativeFees, uint256 tokenFees) = beneficiaryVault.amounts(tokenId);
        assertGt(nativeFees, 0);
        assertGt(tokenFees, 0);
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), beforeLiquidity + 1 ether);
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_increaseLiquidity_noRecipientCodeRunsDuringIncrease() public {
        MockPosmSweeperFeeRecipient attacker = new MockPosmSweeperFeeRecipient(POSITION_MANAGER);
        FeeSplitter splitter =
            new FeeSplitter(POSITION_MANAGER, _splits(_split(address(attacker), 10_000, 10_000, true)));
        (MockERC20 token,, uint256 tokenId) = _positionWithFees(splitter, false);
        attacker.addSweepCurrency(CurrencyLibrary.ADDRESS_ZERO);
        attacker.addSweepCurrency(Currency.wrap(address(weth)));
        attacker.addSweepCurrency(Currency.wrap(address(token)));
        // The recipient's only control window is the collect; the increase itself runs no recipient code,
        // so the caller's PositionManager funding (added afterwards) is out of its reach entirely.
        splitter.collectFees(_single(tokenId));
        assertEq(attacker.sweepAttempts(), 1);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(POSITION_MANAGER), 10 ether);
        token.transfer(address(POSITION_MANAGER), 10 ether);
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));
        splitter.increaseLiquidity(tokenId, 1 ether, 10 ether, 10 ether, bytes(""));
        assertEq(attacker.sweepAttempts(), 1);
        assertEq(address(attacker).balance, attacker.notifiedNative());
        assertEq(token.balanceOf(address(attacker)), attacker.notifiedToken());
        assertEq(weth.balanceOf(address(attacker)), 0);
        assertGt(address(this).balance, ethBefore);
        assertGt(token.balanceOf(address(this)), tokenBefore);
    }

    function test_increaseLiquidity_revertsOnNonNativePool() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 a = new MockERC20("A", "A", 1_000 ether, address(this));
        MockERC20 b = new MockERC20("B", "B", 1_000 ether, address(this));
        (MockERC20 token0, MockERC20 token1) = address(a) < address(b) ? (a, b) : (b, a);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);
        uint256 tokenId = _mintPosition(key, address(splitter), 100 ether, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeSplitter.InvalidBaseCurrency.selector, tokenId, Currency.wrap(address(token0)))
        );
        splitter.increaseLiquidity(tokenId, 1, 1, 1, bytes(""));
    }

    function test_increaseLiquidity_revertsIfSplitterDoesNotOwnPosition() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("T", "T", 1_000 ether, address(this));
        uint256 tokenId = _mintPosition(_initPool(address(token)), address(this), 100 ether, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.NotOwner.selector, tokenId));
        splitter.increaseLiquidity(tokenId, 1, 1, 1, bytes(""));
    }

    receive() external payable {}
}
