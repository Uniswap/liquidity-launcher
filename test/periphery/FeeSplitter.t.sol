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
import {ERC721} from "solady/tokens/ERC721.sol";
import {FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {IFeeSplitter, FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRejectEth} from "../mocks/MockRejectEth.sol";
import {WETH} from "solady/tokens/WETH.sol";

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
    error EthRejected();

    bool internal immutable shouldRevert;
    bool internal immutable rejectEth;
    uint256 public callbackCount;
    uint256 public lastTokenId;
    uint256 public notifiedNative;
    uint256 public notifiedToken;

    constructor(bool _shouldRevert, bool _rejectEth) {
        shouldRevert = _shouldRevert;
        rejectEth = _rejectEth;
    }

    function onFeesReceived(uint256 tokenId, uint256 currency0Amount, uint256 currency1Amount) external {
        if (shouldRevert) revert CallbackFailed();
        callbackCount++;
        lastTokenId = tokenId;
        notifiedNative += currency0Amount;
        notifiedToken += currency1Amount;
    }

    receive() external payable {
        if (rejectEth) revert EthRejected();
    }
}

/// @notice Callback recipient that, when notified during distribution, tries to sweep the
///         PositionManager's standing balances — the increaseLiquidity caller's pre-funded excess.
contract MockPosmSweeperFeeRecipient {
    IPositionManager internal immutable posm;
    Currency[] internal sweepCurrencies;

    uint256 public notifiedNative;
    uint256 public notifiedToken;
    uint256 public sweepAttempts;

    constructor(IPositionManager _posm) {
        posm = _posm;
    }

    function addSweepCurrency(Currency currency) external {
        sweepCurrencies.push(currency);
    }

    function onFeesReceived(uint256, uint256 currency0Amount, uint256 currency1Amount) external {
        notifiedNative += currency0Amount;
        notifiedToken += currency1Amount;

        // No try/catch: if the sweep reverted, the callback would revert and sweepAttempts would
        // stay 0. A recorded attempt means the sweep ran to completion.
        uint256 count = sweepCurrencies.length;
        bytes memory actions = new bytes(count);
        bytes[] memory params = new bytes[](count);
        for (uint256 i; i < count; i++) {
            actions[i] = bytes1(uint8(Actions.SWEEP));
            params[i] = abi.encode(sweepCurrencies[i], address(this));
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

    address internal constant FEE_BENEFICIARY_SENTINEL =
        address(uint160(uint256(keccak256("FeeSplitter.FEE_BENEFICIARY"))));

    PoolSwapTest internal swapRouter;
    WETH internal weth;
    address internal tokenJar = makeAddr("tokenJar");
    address internal creator = makeAddr("creator");

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

    /* ///////////////////////////////////////////////////////////////////////
                                    HELPERS
    /////////////////////////////////////////////////////////////////////// */

    function _splits(address recipient) internal pure returns (FeeSplit[] memory splits) {
        return _splits(recipient, false);
    }

    function _splits(address recipient, bool useCallback) internal pure returns (FeeSplit[] memory splits) {
        splits = new FeeSplit[](1);
        splits[0] = FeeSplit({recipient: recipient, nativeBps: 10_000, tokenBps: 10_000, useCallback: useCallback});
    }

    function _splits(address recipientA, uint16 bpsA, address recipientB, uint16 bpsB)
        internal
        pure
        returns (FeeSplit[] memory splits)
    {
        splits = new FeeSplit[](2);
        splits[0] = FeeSplit({recipient: recipientA, nativeBps: bpsA, tokenBps: bpsA, useCallback: false});
        splits[1] = FeeSplit({recipient: recipientB, nativeBps: bpsB, tokenBps: bpsB, useCallback: false});
    }

    /// @dev The default product configuration: ETH fees to the tokenJar, token fees burned, both with
    ///      a 20% creator share. Fallbacks mirror the non-creator recipient of each side.
    function _defaultSplitter() internal returns (FeeSplitter splitter) {
        FeeSplit[] memory splits = new FeeSplit[](3);
        splits[0] = FeeSplit({recipient: tokenJar, nativeBps: 8_000, tokenBps: 0, useCallback: false});
        splits[1] = FeeSplit({recipient: BURN_ADDRESS, nativeBps: 0, tokenBps: 8_000, useCallback: false});
        splits[2] =
            FeeSplit({recipient: FEE_BENEFICIARY_SENTINEL, nativeBps: 2_000, tokenBps: 2_000, useCallback: false});
        splitter = new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, splits);
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

    /// @dev Replicates the per-side cumulative rounding so per-recipient expectations are exact.
    function _expectedAmounts(uint256 total, FeeSplit[] memory splits, bool nativeSide)
        internal
        pure
        returns (uint256[] memory out)
    {
        out = new uint256[](splits.length);
        uint256 cumulativeBps;
        uint256 distributed;
        for (uint256 i; i < splits.length; i++) {
            cumulativeBps += nativeSide ? splits[i].nativeBps : splits[i].tokenBps;
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

        FeeSplit[] memory stored = splitter.getSplits();
        assertEq(stored.length, 3);
        assertEq(stored[0].recipient, tokenJar);
        assertEq(stored[0].nativeBps, 8_000);
        assertEq(stored[0].tokenBps, 0);
        assertFalse(stored[0].useCallback);
        assertEq(stored[1].recipient, BURN_ADDRESS);
        assertEq(stored[1].nativeBps, 0);
        assertEq(stored[1].tokenBps, 8_000);
        assertFalse(stored[1].useCallback);
        assertEq(stored[2].recipient, FEE_BENEFICIARY_SENTINEL);
        assertEq(stored[2].nativeBps, 2_000);
        assertEq(stored[2].tokenBps, 2_000);
        assertFalse(stored[2].useCallback);

        (address recipient, uint16 nativeBps, uint16 tokenBps, bool useCallback) = splitter.splits(0);
        assertEq(recipient, tokenJar);
        assertEq(nativeBps, 8_000);
        assertEq(tokenBps, 0);
        assertFalse(useCallback);
    }

    function test_constructor_revertsOnInvalidFallback() public {
        FeeSplit[] memory splits = _splits(tokenJar);
        address creatorSentinel = address(uint160(uint256(keccak256("FeeSplitter.FEE_BENEFICIARY"))));

        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidFallback.selector, address(0)));
        new FeeSplitter(POSITION_MANAGER, address(0), BURN_ADDRESS, splits);

        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidFallback.selector, creatorSentinel));
        new FeeSplitter(POSITION_MANAGER, tokenJar, creatorSentinel, splits);

        // A fallback equal to the splitter itself would loop failed sends back into distribution.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidFallback.selector, predicted));
        new FeeSplitter(POSITION_MANAGER, predicted, BURN_ADDRESS, splits);
    }

    function test_constructor_revertsOnEmptySplits() public {
        vm.expectRevert(IFeeSplitter.NoSplits.selector);
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, new FeeSplit[](0));
    }

    function test_constructor_revertsOnInvalidRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidRecipient.selector, address(0)));
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, _splits(address(0)));
    }

    function test_constructor_revertsOnZeroBps() public {
        // Zero on BOTH sides is invalid; a one-sided split is fine (covered by the default config).
        FeeSplit[] memory splits = _splits(tokenJar, 10_000, makeAddr("empty"), 0);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.ZeroSplitBps.selector, makeAddr("empty")));
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, splits);
    }

    function test_constructor_revertsOnDuplicateRecipient() public {
        FeeSplit[] memory splits = _splits(tokenJar, 5_000, tokenJar, 5_000);
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.DuplicateRecipient.selector, tokenJar));
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, splits);
    }

    function test_constructor_revertsOnInvalidTotal(uint16 _bps) public {
        _bps = uint16(bound(_bps, 1, 20_000));
        vm.assume(_bps != 10_000);
        FeeSplit[] memory splits = new FeeSplit[](1);

        // Each side is validated independently: a bad native total reverts even when token is exact...
        splits[0] = FeeSplit({recipient: tokenJar, nativeBps: _bps, tokenBps: 10_000, useCallback: false});
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidSplitTotal.selector, _bps));
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, splits);

        // ...and vice versa.
        splits[0] = FeeSplit({recipient: tokenJar, nativeBps: 10_000, tokenBps: _bps, useCallback: false});
        vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidSplitTotal.selector, _bps));
        new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, splits);
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

        // Split order: [0] tokenJar (native only), [1] burn (token only), [2] sentinel (both).
        uint256[] memory expectedNative = _expectedAmounts(nativeTotal, splitter.getSplits(), true);
        uint256[] memory expectedToken = _expectedAmounts(tokenTotal, splitter.getSplits(), false);
        assertEq(tokenJar.balance - jarNativeBefore, expectedNative[0], "tokenJar native share");
        assertEq(creator.balance - creatorNativeBefore, expectedNative[2], "creator native share");
        assertEq(token.balanceOf(BURN_ADDRESS) - deadTokenBefore, expectedToken[1], "burn token share");
        assertEq(token.balanceOf(creator) - creatorTokenBefore, expectedToken[2], "creator token share");

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
        // Jar native, burn token, and the sentinel's two legs.
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

        uint256 jarNativeBefore = tokenJar.balance;
        uint256 deadTokenBefore = token.balanceOf(BURN_ADDRESS);
        splitter.collectFees(_single(tokenId));

        // The full native side lands on the tokenJar (its 80% + fallback 20%), the full token side on 0xdead.
        assertGt(tokenJar.balance - jarNativeBefore, 0);
        assertGt(token.balanceOf(BURN_ADDRESS) - deadTokenBefore, 0);
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_collectFees_forceSendsNativeToRejectingRecipient() public {
        FeeSplitter splitter = _defaultSplitter();
        // The creator rejects ETH in its receive hook.
        address rejector = address(new MockRejectEth());
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, rejector);

        splitter.collectFees(_single(tokenId));

        // Native shares are force-sent: a reverting receive hook cannot refuse (or block) delivery.
        assertGt(rejector.balance, 0, "rejector native share missing");
        assertGt(token.balanceOf(rejector), 0, "rejector token share missing");
        assertEq(address(splitter).balance, 0);
    }

    function test_collectFees_reentrancyAttemptCannotBlockDistribution() public {
        FeeSplitter splitter = _defaultSplitter();
        uint256 predictedTokenId = POSITION_MANAGER.nextTokenId();
        address reentrant = address(new MockReentrantFeeRecipient(splitter, predictedTokenId));
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, reentrant);
        assertEq(tokenId, predictedTokenId);

        splitter.collectFees(_single(tokenId));

        // The reentrant receive hook reverts on the guard; the share is then force-sent without
        // executing the recipient's code, so the collect completes and nothing is withheld.
        assertGt(reentrant.balance, 0, "reentrant recipient native share missing");
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

    function test_collectFees_assignsRoundingDustAfterZeroValueSplit() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("Plain", "PLAIN", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        uint256 tokenId = _mintPosition(key, address(splitter), 100 ether, 100 ether);
        vm.deal(address(splitter), 1);
        uint256 jarNativeBefore = tokenJar.balance;

        splitter.collectFees(_single(tokenId));

        assertEq(tokenJar.balance - jarNativeBefore, 1);
        assertEq(address(splitter).balance, 0);
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

    function test_collectFees_notifiesCallbackRecipientOncePerCollect() public {
        MockFeeCallback recipient = new MockFeeCallback(false, false);
        FeeSplitter splitter =
            new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, _splits(address(recipient), true));
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        splitter.collectFees(_single(tokenId));

        // One combined callback carrying both sides.
        assertEq(recipient.callbackCount(), 1);
        assertEq(recipient.lastTokenId(), tokenId);
        assertEq(recipient.notifiedNative(), address(recipient).balance);
        assertEq(recipient.notifiedToken(), token.balanceOf(address(recipient)));
        assertGt(address(recipient).balance, 0);
        assertGt(token.balanceOf(address(recipient)), 0);
    }

    function test_collectFees_notifiesResolvedBeneficiary() public {
        MockFeeCallback beneficiary = new MockFeeCallback(false, false);
        FeeSplitter splitter =
            new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, _splits(FEE_BENEFICIARY_SENTINEL, true));
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, address(beneficiary));

        splitter.collectFees(_single(tokenId));

        assertEq(beneficiary.callbackCount(), 1);
        assertEq(beneficiary.lastTokenId(), tokenId);
        assertEq(beneficiary.notifiedNative(), address(beneficiary).balance);
        assertEq(beneficiary.notifiedToken(), token.balanceOf(address(beneficiary)));
    }

    function test_collectFees_callbackReportsForceSentNative() public {
        // The recipient rejects ETH in its receive hook, but the native leg is force-sent, so the
        // callback truthfully reports the full amounts the recipient now holds.
        MockFeeCallback recipient = new MockFeeCallback(false, true);
        FeeSplitter splitter =
            new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, _splits(address(recipient), true));
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        splitter.collectFees(_single(tokenId));

        assertEq(recipient.callbackCount(), 1);
        assertGt(address(recipient).balance, 0, "native share missing despite rejecting receive");
        assertEq(recipient.notifiedNative(), address(recipient).balance);
        assertEq(recipient.notifiedToken(), token.balanceOf(address(recipient)));
    }

    function test_collectFees_unresolvedSentinelSkipsCallback() public {
        // Unregistered position: the sentinel's legs go to the two fallbacks, so no combined
        // callback can be truthfully delivered and none is attempted.
        MockFeeCallback jar = new MockFeeCallback(false, false);
        FeeSplitter splitter =
            new FeeSplitter(POSITION_MANAGER, address(jar), BURN_ADDRESS, _splits(FEE_BENEFICIARY_SENTINEL, true));
        MockERC20 token = new MockERC20("Plain", "PLAIN", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        uint256 tokenId = _mintPosition(key, address(splitter), 100 ether, 100 ether);
        _accrueFees(key);

        splitter.collectFees(_single(tokenId));

        assertEq(jar.callbackCount(), 0);
        assertGt(address(jar).balance, 0, "native leg missing from native fallback");
        assertGt(token.balanceOf(BURN_ADDRESS), 0, "token leg missing from token fallback");
    }

    function test_collectFees_ignoresFailedCallback() public {
        MockFeeCallback recipient = new MockFeeCallback(true, false);
        FeeSplitter splitter =
            new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, _splits(address(recipient), true));
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        splitter.collectFees(_single(tokenId));

        assertEq(recipient.callbackCount(), 0);
        assertGt(address(recipient).balance, 0);
        assertGt(token.balanceOf(address(recipient)), 0);
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_collectFees_skipsDisabledCallback() public {
        MockFeeCallback recipient = new MockFeeCallback(false, false);
        FeeSplitter splitter = new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, _splits(address(recipient)));
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        splitter.collectFees(_single(tokenId));

        assertEq(recipient.callbackCount(), 0);
        assertGt(address(recipient).balance, 0);
        assertGt(token.balanceOf(address(recipient)), 0);
    }

    function test_increaseLiquidity_usesPositionManagerBalancesAndRefundsExcess() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        uint256 tokenId = _mintPosition(key, address(splitter), 100 ether, 100 ether);
        uint128 liquidityBefore = POSITION_MANAGER.getPositionLiquidity(tokenId);
        uint256 liquidityIncrease = 1 ether;
        uint128 amount0Max = 10 ether;
        uint128 amount1Max = 10 ether;

        weth.deposit{value: amount0Max}();
        weth.transfer(address(POSITION_MANAGER), amount0Max);
        token.transfer(address(POSITION_MANAGER), amount1Max);
        uint256 ethBefore = address(this).balance;
        uint256 tokenBefore = token.balanceOf(address(this));

        splitter.increaseLiquidity(tokenId, liquidityIncrease, amount0Max, amount1Max, bytes(""));

        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), liquidityBefore + liquidityIncrease);
        assertGt(address(this).balance, ethBefore);
        assertGt(token.balanceOf(address(this)), tokenBefore);
        assertEq(weth.balanceOf(address(POSITION_MANAGER)), 0);
        assertEq(address(POSITION_MANAGER).balance, 0);
        assertEq(token.balanceOf(address(POSITION_MANAGER)), 0);
    }

    function test_increaseLiquidity_distributesPendingFeesBeforeIncrease() public {
        FeeSplitter splitter = _defaultSplitter();
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);
        uint128 liquidityBefore = POSITION_MANAGER.getPositionLiquidity(tokenId);
        uint256 liquidityIncrease = 1 ether;
        uint128 amount0Max = 10 ether;
        uint128 amount1Max = 10 ether;

        weth.deposit{value: amount0Max}();
        weth.transfer(address(POSITION_MANAGER), amount0Max);
        token.transfer(address(POSITION_MANAGER), amount1Max);

        uint256 jarBefore = tokenJar.balance;
        uint256 creatorEthBefore = creator.balance;
        uint256 burnBefore = token.balanceOf(BURN_ADDRESS);
        uint256 creatorTokenBefore = token.balanceOf(creator);

        splitter.increaseLiquidity(tokenId, liquidityIncrease, amount0Max, amount1Max, bytes(""));

        // The accrued fees flowed through the configured splits instead of being folded into the
        // increase or swept to the caller with the excess.
        assertGt(tokenJar.balance, jarBefore);
        assertGt(creator.balance, creatorEthBefore);
        assertGt(token.balanceOf(BURN_ADDRESS), burnBefore);
        assertGt(token.balanceOf(creator), creatorTokenBefore);
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), liquidityBefore + liquidityIncrease);
        assertEq(address(splitter).balance, 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_increaseLiquidity_recipientCannotSweepCallerExcessFromPositionManager() public {
        // A malicious fee recipient sweeps POSM's balances when its callback fires. Distribution
        // runs only after the increase has consumed the caller's pre-fund and refunded the excess,
        // so the sweep executes against an empty PositionManager and captures nothing.
        MockPosmSweeperFeeRecipient attacker = new MockPosmSweeperFeeRecipient(POSITION_MANAGER);
        FeeSplitter splitter =
            new FeeSplitter(POSITION_MANAGER, tokenJar, BURN_ADDRESS, _splits(address(attacker), true));
        (MockERC20 token,, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);
        attacker.addSweepCurrency(CurrencyLibrary.ADDRESS_ZERO);
        attacker.addSweepCurrency(Currency.wrap(address(weth)));
        attacker.addSweepCurrency(Currency.wrap(address(token)));
        uint128 liquidityBefore = POSITION_MANAGER.getPositionLiquidity(tokenId);
        uint256 liquidityIncrease = 1 ether;
        uint128 amount0Max = 10 ether;
        uint128 amount1Max = 10 ether;

        weth.deposit{value: amount0Max}();
        weth.transfer(address(POSITION_MANAGER), amount0Max);
        token.transfer(address(POSITION_MANAGER), amount1Max);
        uint256 callerEthBefore = address(this).balance;
        uint256 callerTokenBefore = token.balanceOf(address(this));

        splitter.increaseLiquidity(tokenId, liquidityIncrease, amount0Max, amount1Max, bytes(""));

        // The sweep ran to completion but yielded nothing beyond the attacker's own fee share.
        assertEq(attacker.sweepAttempts(), 1, "sweep attempt did not run");
        assertEq(address(attacker).balance, attacker.notifiedNative(), "attacker holds more native than its share");
        assertEq(token.balanceOf(address(attacker)), attacker.notifiedToken(), "attacker holds more than its share");
        assertEq(weth.balanceOf(address(attacker)), 0, "attacker captured pre-funded WETH");
        assertGt(attacker.notifiedNative(), 0, "fees were not distributed");

        // The caller's excess was refunded before any recipient code ran.
        assertGt(address(this).balance, callerEthBefore, "caller native refund missing");
        assertGt(token.balanceOf(address(this)), callerTokenBefore, "caller token refund missing");
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), liquidityBefore + liquidityIncrease);
        assertEq(weth.balanceOf(address(POSITION_MANAGER)), 0);
        assertEq(address(POSITION_MANAGER).balance, 0);
        assertEq(token.balanceOf(address(POSITION_MANAGER)), 0);
    }

    function test_increaseLiquidity_revertsOnNonNativePool() public {
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

        vm.expectRevert(
            abi.encodeWithSelector(IFeeSplitter.InvalidBaseCurrency.selector, tokenId, Currency.wrap(address(token0)))
        );
        splitter.increaseLiquidity(tokenId, 1, 1, 1, bytes(""));
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
        // No transfer data: no beneficiary NFT exists for this position.
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        splitter.ownerOf(tokenId);
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
        assertEq(splitter.ownerOf(tokenId), beneficiary);

        // The registered beneficiary receives the sentinel shares on both sides.
        splitter.collectFees(_single(tokenId));
        assertGt(beneficiary.balance, 0);
        assertGt(token.balanceOf(beneficiary), 0);
    }

    function test_beneficiaryNft_transferMovesTheFeeStream() public {
        FeeSplitter splitter = _defaultSplitter();
        (MockERC20 token, PoolKey memory key, uint256 tokenId) = _setUpPositionWithFees(splitter, creator);

        // First collect pays the original beneficiary.
        splitter.collectFees(_single(tokenId));
        uint256 creatorNative = creator.balance;
        assertGt(creatorNative, 0);

        // The beneficiary transfers the fee stream by transferring the splitter's NFT.
        address newBeneficiary = makeAddr("newBeneficiary");
        vm.prank(creator);
        splitter.transferFrom(creator, newBeneficiary, tokenId);
        assertEq(splitter.ownerOf(tokenId), newBeneficiary);

        // Subsequent fees go to the new holder; the old beneficiary earns nothing further.
        _accrueFees(key);
        splitter.collectFees(_single(tokenId));
        assertGt(newBeneficiary.balance, 0);
        assertGt(token.balanceOf(newBeneficiary), 0);
        assertEq(creator.balance, creatorNative);
    }

    function test_onERC721Received_revertsOnInvalidBeneficiary() public {
        FeeSplitter splitter = _defaultSplitter();
        MockERC20 token = new MockERC20("Launched", "LAUNCH", 1_000_000 ether, address(this));
        PoolKey memory key = _initPool(address(token));
        uint256 tokenId = _mintPosition(key, address(this), 100 ether, 100 ether);

        // Same hygiene as the constructor's split recipients: zero, the splitter, and the sentinel.
        address[3] memory invalid = [address(0), address(splitter), FEE_BENEFICIARY_SENTINEL];
        for (uint256 i; i < invalid.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(IFeeSplitter.InvalidRecipient.selector, invalid[i]));
            IERC721(address(POSITION_MANAGER))
                .safeTransferFrom(address(this), address(splitter), tokenId, abi.encode(invalid[i]));
        }
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
