// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// Concrete imports so deployCodeTo finds the artifacts.
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {IFeeSplitter, FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRejectEth} from "../mocks/MockRejectEth.sol";

/// @notice Native recipient that attempts to reenter collectFees from its receive hook.
contract MockReentrantFeeRecipient {
    FeeSplitter internal immutable splitter;
    uint256 internal immutable tokenId;

    constructor(FeeSplitter _splitter, uint256 _tokenId) {
        splitter = _splitter;
        tokenId = _tokenId;
    }

    receive() external payable {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        splitter.collectFees(tokenIds);
    }
}

contract MockFeeCallback {
    error CallbackFailed();

    bool internal immutable shouldRevert;
    uint256 public callbackCount;
    uint256 public lastTokenId;
    mapping(Currency currency => uint256 amount) public notified;

    constructor(bool _shouldRevert) {
        shouldRevert = _shouldRevert;
    }

    function onFeesReceived(uint256 tokenId, Currency currency, uint256 amount) external {
        if (shouldRevert) revert CallbackFailed();
        callbackCount++;
        lastTokenId = tokenId;
        notified[currency] += amount;
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

    address internal constant FEE_BENEFICIARY_SENTINEL =
        address(uint160(uint256(keccak256("FeeSplitter.FEE_BENEFICIARY"))));

    PoolSwapTest internal swapRouter;
    address internal tokenJar = makeAddr("tokenJar");
    address internal creator = makeAddr("creator");

    function setUp() public {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        vm.deal(address(this), 10_000 ether);
    }

    /* ///////////////////////////////////////////////////////////////////////
                                    HELPERS
    /////////////////////////////////////////////////////////////////////// */

    function _splits(address recipient) internal pure returns (FeeSplit[] memory splits) {
        return _splits(recipient, false);
    }

    function _splits(address recipient, bool useCallback) internal pure returns (FeeSplit[] memory splits) {
        splits = new FeeSplit[](1);
        splits[0] = FeeSplit({recipient: recipient, bps: 10_000, useCallback: useCallback});
    }

    function _splits(address recipientA, uint16 bpsA, address recipientB, uint16 bpsB)
        internal
        pure
        returns (FeeSplit[] memory splits)
    {
        splits = new FeeSplit[](2);
        splits[0] = FeeSplit({recipient: recipientA, bps: bpsA, useCallback: false});
        splits[1] = FeeSplit({recipient: recipientB, bps: bpsB, useCallback: false});
    }

    /// @dev The default product configuration: ETH fees to the tokenJar, token fees burned, both with
    ///      a 20% creator share. Fallbacks mirror the non-creator recipient of each side.
    function _defaultSplitter() internal returns (FeeSplitter splitter) {
        splitter = new FeeSplitter(
            POSITION_MANAGER,
            tokenJar,
            BURN_ADDRESS,
            _splits(tokenJar, 8_000, FEE_BENEFICIARY_SENTINEL, 2_000),
            _splits(BURN_ADDRESS, 8_000, FEE_BENEFICIARY_SENTINEL, 2_000)
        );
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

    /// @dev Mints a full-range position paying with this contract's native/token balances.
    function _mintPosition(PoolKey memory key, address recipient, uint256 amount0, uint256 amount1)
        internal
        returns (uint256 tokenId)
    {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, amount0, amount1, recipient, bytes(""));
        params[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency0, key.currency1, address(this));

        tokenId = POSITION_MANAGER.nextTokenId();
        uint256 value;
        if (key.currency0.isAddressZero()) {
            value = amount0;
        } else {
            IERC20(Currency.unwrap(key.currency0)).transfer(address(POSITION_MANAGER), amount0);
        }
        IERC20(Currency.unwrap(key.currency1)).transfer(address(POSITION_MANAGER), amount1);
        POSITION_MANAGER.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp);
    }

    /// @dev Swaps both directions so the position accrues fees in both currencies.
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

    /// @dev Launches a fresh token + pool + position deposited into the splitter with the given
    ///      registered beneficiary, with accrued fees.
    function _setUpPositionWithFees(FeeSplitter splitter, address beneficiary)
        internal
        returns (MockERC20 token, PoolKey memory key, uint256 tokenId)
    {
        token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        key = _initPool(address(token));
        tokenId = _mintPosition(key, address(this), 100 ether, 100 ether);
        IERC721(address(POSITION_MANAGER))
            .safeTransferFrom(address(this), address(splitter), tokenId, abi.encode(beneficiary));
        _accrueFees(key);
    }

    /// @dev Replicates the cumulative rounding so per-recipient expectations are exact.
    function _expectedAmounts(uint256 total, FeeSplit[] memory splits) internal pure returns (uint256[] memory out) {
        out = new uint256[](splits.length);
        uint256 cumulativeBps;
        uint256 distributed;
        for (uint256 i; i < splits.length; i++) {
            cumulativeBps += splits[i].bps;
            uint256 cumulativeAmount = FullMath.mulDiv(total, cumulativeBps, 10_000);
            out[i] = cumulativeAmount - distributed;
            distributed = cumulativeAmount;
        }
    }

    function _single(uint256 tokenId) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
    }

    /* ///////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    /////////////////////////////////////////////////////////////////////// */

    function test_constructor_storesImmutableConfiguration() public {
        FeeSplitter splitter = _defaultSplitter();

        assertEq(address(splitter.positionManager()), address(POSITION_MANAGER));
        assertEq(splitter.nativeFallback(), tokenJar);
        assertEq(splitter.tokenFallback(), BURN_ADDRESS);

        FeeSplit[] memory native = splitter.getNativeSplits();
        assertEq(native.length, 2);
        assertEq(native[0].recipient, tokenJar);
        assertEq(native[0].bps, 8_000);
        assertFalse(native[0].useCallback);
        assertEq(native[1].recipient, FEE_BENEFICIARY_SENTINEL);
        assertEq(native[1].bps, 2_000);
        assertFalse(native[1].useCallback);

        FeeSplit[] memory tokenSide = splitter.getTokenSplits();
        assertEq(tokenSide.length, 2);
        assertEq(tokenSide[0].recipient, BURN_ADDRESS);
        assertEq(tokenSide[0].bps, 8_000);
        assertFalse(tokenSide[0].useCallback);
        assertEq(tokenSide[1].recipient, FEE_BENEFICIARY_SENTINEL);
        assertEq(tokenSide[1].bps, 2_000);
        assertFalse(tokenSide[1].useCallback);
    }

    function test_constructor_revertsOnInvalidFallback() public {
        FeeSplit[] memory splits = _splits(tokenJar);
        address creatorSentinel = address(uint160(uint256(keccak256("FeeSplitter.FEE_BENEFICIARY"))));

        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidFallback.selector, address(0)));
        new FeeSplitter(POSITION_MANAGER, address(0), BURN_ADDRESS, splits, splits);

        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidFallback.selector, creatorSentinel));
        new FeeSplitter(POSITION_MANAGER, tokenJar, creatorSentinel, splits, splits);

        // A fallback equal to the splitter itself would loop failed sends back into distribution.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidFallback.selector, predicted));
        new FeeSplitter(POSITION_MANAGER, predicted, BURN_ADDRESS, splits, splits);
    }

    function test_constructor_revertsOnEmptySplits() public {
        vm.expectRevert(IFeeSplitter.NoSplits.selector);
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, new FeeSplit[](0), _splits(BURN_ADDRESS));
    }

    function test_constructor_revertsOnInvalidRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidRecipient.selector, address(0)));
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, _splits(address(0)), _splits(BURN_ADDRESS));
    }

    function test_constructor_revertsOnZeroBps() public {
        FeeSplit[] memory splits = _splits(tokenJar, 10_000, makeAddr("empty"), 0);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.ZeroSplitBps.selector, makeAddr("empty")));
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, splits, _splits(BURN_ADDRESS));
    }

    function test_constructor_revertsOnDuplicateRecipient() public {
        FeeSplit[] memory splits = _splits(tokenJar, 5_000, tokenJar, 5_000);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.DuplicateRecipient.selector, tokenJar));
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, splits, _splits(BURN_ADDRESS));
    }

    function test_constructor_revertsOnInvalidTotal(uint16 _bps) public {
        _bps = uint16(bound(_bps, 1, 20_000));
        vm.assume(_bps != 10_000);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidSplitTotal.selector, _bps));
        FeeSplit[] memory splits = new FeeSplit[](1);
        splits[0] = FeeSplit({recipient: tokenJar, bps: _bps, useCallback: false});
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, splits, _splits(BURN_ADDRESS));
    }

    /* ///////////////////////////////////////////////////////////////////////
                                  COLLECT FEES
    /////////////////////////////////////////////////////////////////////// */

    function test_collectFees_revertsOnEmptyTokenIds() public {
        FeeSplitter splitter = _defaultSplitter();
        vm.expectRevert(IFeeSplitter.NoTokenIds.selector);
        splitter.collectFees(new uint256[](0));
    }

    function test_collectFees_revertsIfNotOwner() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        // Position owned by the test contract, not the splitter.
        uint256 tokenId = _mintPosition(key, address(this), 100 ether, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(splitter)));
        splitter.collectFees(_single(tokenId));
    }

    function test_collectFees_revertsOnNonNativePool() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 tokenA = new MockERC20("A", "A", 1_000_000 ether, address(this));
        MockERC20 tokenB = new MockERC20("B", "B", 1_000_000 ether, address(this));
        (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(0))});
        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);
        uint256 tokenId = _mintPosition(key, address(splitter), 100 ether, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidBaseCurrency.selector, tokenId, c0));
        splitter.collectFees(_single(tokenId));
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_collectFees_distributesBothSidesToRegisteredBeneficiary() public {
        FeeSplitter splitter = _defaultSplitter();
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        uint256 jarNativeBefore = tokenJar.balance;
        uint256 creatorNativeBefore = creator.balance;
        uint256 deadTokenBefore = token.balanceOf(BURN_ADDRESS);
        uint256 creatorTokenBefore = token.balanceOf(creator);

        splitter.collectFees(_single(tokenId));
        vm.snapshotGasLastCall("FeeSplitter.collectFees");

        uint256 nativeTotal = (tokenJar.balance - jarNativeBefore) + (creator.balance - creatorNativeBefore);
        uint256 tokenTotal =
            (token.balanceOf(BURN_ADDRESS) - deadTokenBefore) + (token.balanceOf(creator) - creatorTokenBefore);
        assertGt(nativeTotal, 0, "no native fees collected");
        assertGt(tokenTotal, 0, "no token fees collected");

        uint256[] memory expectedNative = _expectedAmounts(nativeTotal, splitter.getNativeSplits());
        uint256[] memory expectedToken = _expectedAmounts(tokenTotal, splitter.getTokenSplits());
        assertEq(tokenJar.balance - jarNativeBefore, expectedNative[0], "tokenJar native share");
        assertEq(creator.balance - creatorNativeBefore, expectedNative[1], "creator native share");
        assertEq(token.balanceOf(BURN_ADDRESS) - deadTokenBefore, expectedToken[0], "burn token share");
        assertEq(token.balanceOf(creator) - creatorTokenBefore, expectedToken[1], "creator token share");

        assertEq(address(splitter).balance, 0, "splitter retained native");
        assertEq(token.balanceOf(address(splitter)), 0, "splitter retained token");
        // Position stays with the splitter and remains collectable.
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(splitter));
    }

    function test_collectFees_emitsEvents() public {
        FeeSplitter splitter = _defaultSplitter();
        (,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        vm.recordLogs();
        splitter.collectFees(_single(tokenId));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 collected;
        uint256 forwarded;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(splitter)) continue;
            if (logs[i].topics[0] == IFeeSplitter.FeesCollected.selector) collected++;
            if (logs[i].topics[0] == IFeeSplitter.FeesForwarded.selector) forwarded++;
        }
        assertEq(collected, 1, "one FeesCollected");
        // Two recipients per side, both sides nonzero.
        assertEq(forwarded, 4, "four FeesForwarded");
    }

    function test_collectFees_unregisteredPositionFallsBackPerSide() public {
        FeeSplitter splitter = _defaultSplitter();
        // Minted directly to the splitter: no receiver callback, so no registered beneficiary —
        // the sentinel shares go straight to the per-side fallbacks.
        MockERC20 token = new MockERC20("Plain", "PLAIN", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        uint256 tokenId = _mintPosition(key, address(splitter), 100 ether, 100 ether);
        _accrueFees(key);
        assertEq(splitter.feeBeneficiary(tokenId), address(0));

        uint256 jarNativeBefore = tokenJar.balance;
        uint256 deadTokenBefore = token.balanceOf(BURN_ADDRESS);
        splitter.collectFees(_single(tokenId));

        // The full native side lands on the tokenJar (its 80% + fallback 20%), the full token side on 0xdead.
        assertGt(tokenJar.balance - jarNativeBefore, 0);
        assertGt(token.balanceOf(BURN_ADDRESS) - deadTokenBefore, 0);
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_collectFees_nativeSendFailureRoutesToFallback() public {
        FeeSplitter splitter = _defaultSplitter();
        // The creator rejects ETH but accepts ERC20s.
        address rejector = address(new MockRejectEth());
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, rejector);

        uint256 jarNativeBefore = tokenJar.balance;
        splitter.collectFees(_single(tokenId));

        // The creator's native share was redirected to the native fallback (the tokenJar); the token
        // share still reaches the rejecting creator since ERC20 transfers have no receive hook.
        assertEq(rejector.balance, 0, "rejector received native");
        assertGt(token.balanceOf(rejector), 0, "rejector token share missing");
        assertGt(tokenJar.balance - jarNativeBefore, 0);
        assertEq(address(splitter).balance, 0);
    }

    function test_collectFees_reentrancyAttemptRoutesToFallback() public {
        FeeSplitter splitter = _defaultSplitter();
        uint256 predictedTokenId = POSITION_MANAGER.nextTokenId();
        address reentrant = address(new MockReentrantFeeRecipient(splitter, predictedTokenId));
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, reentrant);
        assertEq(tokenId, predictedTokenId);

        uint256 jarNativeBefore = tokenJar.balance;
        splitter.collectFees(_single(tokenId));

        // The reentrant receive hook reverts on the guard, so its native share lands on the fallback.
        assertEq(reentrant.balance, 0, "reentrant recipient received native");
        assertGt(tokenJar.balance - jarNativeBefore, 0);
        assertGt(token.balanceOf(reentrant), 0, "token share missing");
        assertEq(address(splitter).balance, 0);
    }

    function test_collectFees_batchAttributesFeesPerPool() public {
        FeeSplitter splitter = _defaultSplitter();
        address creatorA = makeAddr("creatorA");
        address creatorB = makeAddr("creatorB");
        (MockERC20 tokenA,, uint256 tokenIdA) = _setUpPositionWithFees(splitter, creatorA);
        (MockERC20 tokenB,, uint256 tokenIdB) = _setUpPositionWithFees(splitter, creatorB);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenIdA;
        tokenIds[1] = tokenIdB;
        splitter.collectFees(tokenIds);

        // Each creator earns only its own pool's token, and both earn native.
        assertGt(tokenA.balanceOf(creatorA), 0);
        assertEq(tokenA.balanceOf(creatorB), 0);
        assertGt(tokenB.balanceOf(creatorB), 0);
        assertEq(tokenB.balanceOf(creatorA), 0);
        assertGt(creatorA.balance, 0);
        assertGt(creatorB.balance, 0);
        assertEq(address(splitter).balance, 0);
        assertEq(tokenA.balanceOf(address(splitter)), 0);
        assertEq(tokenB.balanceOf(address(splitter)), 0);
    }

    function test_collectFees_distributesDonatedBalances() public {
        FeeSplitter splitter = _defaultSplitter();
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        vm.deal(address(splitter), 5 ether);
        token.transfer(address(splitter), 7 ether);

        uint256 jarNativeBefore = tokenJar.balance;
        uint256 creatorNativeBefore = creator.balance;
        splitter.collectFees(_single(tokenId));

        // Donations are flushed through the split along with the collected fees.
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
        uint256 nativeTotal = (tokenJar.balance - jarNativeBefore) + (creator.balance - creatorNativeBefore);
        assertGt(nativeTotal, 5 ether, "donated native not distributed");
        assertGt(token.balanceOf(BURN_ADDRESS), 7 ether * 8_000 / 10_000, "donated token not burned pro rata");
    }

    function test_collectFees_secondCollectDistributesNewFeesOnly() public {
        FeeSplitter splitter = _defaultSplitter();
        (MockERC20 token, PoolKey memory key, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        splitter.collectFees(_single(tokenId));
        uint256 creatorNativeAfterFirst = creator.balance;

        // No new fees: a second collect distributes nothing.
        splitter.collectFees(_single(tokenId));
        assertEq(creator.balance, creatorNativeAfterFirst);

        // New swaps accrue fresh fees that are then distributed.
        _accrueFees(key);
        splitter.collectFees(_single(tokenId));
        assertGt(creator.balance, creatorNativeAfterFirst);
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_collectFees_notifiesCallbackRecipients() public {
        MockFeeCallback recipient = new MockFeeCallback(false);
        FeeSplitter splitter = new FeeSplitter(
            POSITION_MANAGER,
            tokenJar,
            BURN_ADDRESS,
            _splits(address(recipient), true),
            _splits(address(recipient), true)
        );
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        splitter.collectFees(_single(tokenId));

        assertEq(recipient.callbackCount(), 2);
        assertEq(recipient.lastTokenId(), tokenId);
        assertEq(recipient.notified(CurrencyLibrary.ADDRESS_ZERO), address(recipient).balance);
        assertEq(recipient.notified(Currency.wrap(address(token))), token.balanceOf(address(recipient)));
        assertGt(address(recipient).balance, 0);
        assertGt(token.balanceOf(address(recipient)), 0);
    }

    function test_collectFees_notifiesResolvedBeneficiary() public {
        MockFeeCallback beneficiary = new MockFeeCallback(false);
        FeeSplitter splitter = new FeeSplitter(
            POSITION_MANAGER,
            tokenJar,
            BURN_ADDRESS,
            _splits(FEE_BENEFICIARY_SENTINEL, true),
            _splits(FEE_BENEFICIARY_SENTINEL, true)
        );
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, address(beneficiary));

        splitter.collectFees(_single(tokenId));

        assertEq(beneficiary.callbackCount(), 2);
        assertEq(beneficiary.lastTokenId(), tokenId);
        assertEq(beneficiary.notified(CurrencyLibrary.ADDRESS_ZERO), address(beneficiary).balance);
        assertEq(beneficiary.notified(Currency.wrap(address(token))), token.balanceOf(address(beneficiary)));
    }

    function test_collectFees_ignoresFailedCallback() public {
        MockFeeCallback recipient = new MockFeeCallback(true);
        FeeSplitter splitter = new FeeSplitter(
            POSITION_MANAGER,
            tokenJar,
            BURN_ADDRESS,
            _splits(address(recipient), true),
            _splits(address(recipient), true)
        );
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        splitter.collectFees(_single(tokenId));

        assertEq(recipient.callbackCount(), 0);
        assertGt(address(recipient).balance, 0);
        assertGt(token.balanceOf(address(recipient)), 0);
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_collectFees_skipsDisabledCallback() public {
        MockFeeCallback recipient = new MockFeeCallback(false);
        FeeSplitter splitter = new FeeSplitter(
            POSITION_MANAGER, tokenJar, BURN_ADDRESS, _splits(address(recipient)), _splits(address(recipient))
        );
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        splitter.collectFees(_single(tokenId));

        assertEq(recipient.callbackCount(), 0);
        assertGt(address(recipient).balance, 0);
        assertGt(token.balanceOf(address(recipient)), 0);
    }

    function test_increaseLiquidity_usesPositionManagerBalancesAndRefundsExcess() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 tokenA = new MockERC20("Token A", "A", 1_000_000 ether, address(this));
        MockERC20 tokenB = new MockERC20("Token B", "B", 1_000_000 ether, address(this));
        (MockERC20 token0, MockERC20 token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);
        uint256 tokenId = _mintPosition(key, address(splitter), 100 ether, 100 ether);
        uint128 liquidityBefore = POSITION_MANAGER.getPositionLiquidity(tokenId);
        uint256 liquidityIncrease = 1 ether;
        uint128 amount0Max = 10 ether;
        uint128 amount1Max = 10 ether;

        token0.transfer(address(POSITION_MANAGER), amount0Max);
        token1.transfer(address(POSITION_MANAGER), amount1Max);
        uint256 token0Before = token0.balanceOf(address(this));
        uint256 token1Before = token1.balanceOf(address(this));

        splitter.increaseLiquidity(tokenId, liquidityIncrease, amount0Max, amount1Max, bytes(""));

        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), liquidityBefore + liquidityIncrease);
        assertGt(token0.balanceOf(address(this)), token0Before);
        assertGt(token1.balanceOf(address(this)), token1Before);
        assertEq(token0.balanceOf(address(POSITION_MANAGER)), 0);
        assertEq(token1.balanceOf(address(POSITION_MANAGER)), 0);
    }

    function test_increaseLiquidity_revertsIfSplitterDoesNotOwnPosition() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        uint256 tokenId = _mintPosition(key, address(this), 100 ether, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.NotOwner.selector, tokenId));
        splitter.increaseLiquidity(tokenId, 1, 1, 1, bytes(""));
    }

    /* ///////////////////////////////////////////////////////////////////////
                                     MISC
    /////////////////////////////////////////////////////////////////////// */

    function test_onERC721Received_acceptsSafeTransfers() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        uint256 tokenId = _mintPosition(key, address(this), 100 ether, 100 ether);

        IERC721(address(POSITION_MANAGER)).safeTransferFrom(address(this), address(splitter), tokenId);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(splitter));
        // No transfer data: nothing registered, resolution falls back to the token's creator().
        assertEq(splitter.feeBeneficiary(tokenId), address(0));
    }

    function test_onERC721Received_registersBeneficiaryFromTransferData() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        uint256 tokenId = _mintPosition(key, address(this), 100 ether, 100 ether);
        _accrueFees(key);

        address beneficiary = makeAddr("beneficiary");
        IERC721(address(POSITION_MANAGER))
            .safeTransferFrom(address(this), address(splitter), tokenId, abi.encode(beneficiary));
        assertEq(splitter.feeBeneficiary(tokenId), beneficiary);

        // The registered beneficiary receives the sentinel shares on both sides.
        splitter.collectFees(_single(tokenId));
        assertGt(beneficiary.balance, 0);
        assertGt(token.balanceOf(beneficiary), 0);
    }

    function test_onERC721Received_revertsOnZeroBeneficiary() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        uint256 tokenId = _mintPosition(key, address(this), 100 ether, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidRecipient.selector, address(0)));
        IERC721(address(POSITION_MANAGER))
            .safeTransferFrom(address(this), address(splitter), tokenId, abi.encode(address(0)));
    }

    function test_onERC721Received_revertsForNonPositionManagerNFTs() public {
        FeeSplitter splitter = _defaultSplitter();
        // Foreign NFTs would be irrecoverably stuck: the splitter only interacts with the canonical
        // PositionManager, so their safe transfers are rejected at the callback.
        address impostor = makeAddr("impostorNFT");
        vm.prank(impostor);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.NotPositionManager.selector, impostor));
        splitter.onERC721Received(address(this), address(this), 1, bytes(""));
    }

    function test_canReceiveEth() public {
        FeeSplitter splitter = _defaultSplitter();
        (bool success,) = address(splitter).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(splitter).balance, 1 ether);
    }

    receive() external payable {}
}
