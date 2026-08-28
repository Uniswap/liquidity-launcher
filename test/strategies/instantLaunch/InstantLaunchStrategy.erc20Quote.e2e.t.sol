// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// End-to-end coverage for instant launches against an ERC20 quote currency, in both orientations:
// the token as currency1 (quote sorts below) and the token-as-currency0 pool (quote sorts
// above). Fee collection through the FeeSplitter still requires a native currency0 and is asserted
// as such below.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {InstantLaunchStrategy} from "../../../src/strategies/InstantLaunchStrategy.sol";
import {IFeeSplitter} from "../../../src/interfaces/IFeeSplitter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {InstantLaunchTestBase} from "./base/InstantLaunchTestBase.sol";

contract InstantLaunchStrategyErc20QuoteE2ETest is InstantLaunchTestBase {
    using StateLibrary for IPoolManager;

    PoolSwapTest internal swapRouter;

    function setUp() public override {
        super.setUp();
        swapRouter = new PoolSwapTest(POOL_MANAGER);
    }

    /// @notice Launches a fresh token through a strategy quoted in the ERC20 etched at `quoteAddress`.
    function _launchWithQuote(address quoteAddress)
        internal
        returns (MockERC20 quote, MockERC20 token, PoolKey memory key, uint256 tokenId)
    {
        quote = _deployQuoteToken(quoteAddress);
        InstantLaunchStrategy erc20QuoteStrategy =
            _deployStrategy(Currency.wrap(address(quote)), INITIAL_TICK, MIN_LAUNCH_TICK, MAX_INITIAL_TICK);
        token = _deployToken(TOTAL_SUPPLY);
        tokenId = POSITION_MANAGER.nextTokenId();

        _initialize(erc20QuoteStrategy, IERC20(address(token)), TOTAL_SUPPLY, _defaultConfig());

        (address currency0, address currency1) =
            address(token) < address(quote) ? (address(token), address(quote)) : (address(quote), address(token));
        key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: erc20QuoteStrategy.LP_FEE(),
            tickSpacing: erc20QuoteStrategy.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        quote.approve(address(swapRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
    }

    function test_erc20Quote_buyPaysQuoteAndReceivesToken() public {
        // The quote sorts below every test token: the token stays currency1 and buys push the
        // price down, exactly as in the native pools.
        (MockERC20 quote, MockERC20 token, PoolKey memory key,) = _launchWithQuote(LOW_QUOTE_ADDRESS);
        uint256 quoteBefore = quote.balanceOf(address(this));

        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        assertEq(delta.amount0(), -10 ether);
        assertGt(delta.amount1(), 0);
        assertEq(quoteBefore - quote.balanceOf(address(this)), 10 ether);
        assertGt(token.balanceOf(address(this)), 0);
    }

    function test_quote1_launchMintsSingleSidedPositionWithFullSupply() public {
        (, MockERC20 token, PoolKey memory key, uint256 tokenId) = _launchWithQuote(HIGH_QUOTE_ADDRESS);

        // The quote-as-currency1 pool opens at the negated tick with the full supply above the price.
        (uint160 sqrtPriceX96, int24 tick,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(tick, -INITIAL_TICK);
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-INITIAL_TICK));
        assertEq(Currency.unwrap(key.currency0), address(token));

        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        assertEq(info.tickLower(), -INITIAL_TICK);
        assertEq(info.tickUpper(), -MIN_LAUNCH_TICK);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(feeSplitter));

        // Whole supply accounted for: everything is in the pool except burned rounding dust.
        assertEq(token.balanceOf(address(POOL_MANAGER)) + token.balanceOf(address(0xdead)), TOTAL_SUPPLY);
        assertLt(token.balanceOf(address(0xdead)), 1 ether);
    }

    function test_quote1_swapExactOutput_succeedsAtInitialBoundary() public {
        (, MockERC20 token, PoolKey memory key,) = _launchWithQuote(HIGH_QUOTE_ADDRESS);
        uint256 requestedOutput = 1 ether;
        uint256 balanceBefore = token.balanceOf(address(this));

        // The token is currency0, so a buy pays quote (currency1) and pushes the price up.
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: int256(requestedOutput),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        assertEq(delta.amount0(), int128(uint128(requestedOutput)));
        assertLt(delta.amount1(), 0);
        assertEq(token.balanceOf(address(this)) - balanceBefore, requestedOutput);
    }

    function test_quote1_largeBuyMovesPriceUpAndPoolKeepsTrading() public {
        (, MockERC20 token, PoolKey memory key,) = _launchWithQuote(HIGH_QUOTE_ADDRESS);

        // A large buy has no terminal tick or phase change: the price walks up the single position
        // and the pool keeps trading in the same block.
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(100_000 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        assertGt(delta.amount0(), 0);
        assertEq(delta.amount1(), -int256(100_000 ether));

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertGt(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-INITIAL_TICK));
        assertLt(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-MIN_LAUNCH_TICK));

        // Buys and sells both work immediately after — nothing gates the pool.
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -1_000 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        assertGt(token.balanceOf(address(this)), 0);
    }

    function test_quote1_sellAfterBuyReturnsQuote() public {
        (MockERC20 quote, MockERC20 token, PoolKey memory key,) = _launchWithQuote(HIGH_QUOTE_ADDRESS);

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        uint256 tokenBalance = token.balanceOf(address(this));
        uint256 quoteBefore = quote.balanceOf(address(this));
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(tokenBalance), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        // The round trip returns quote (less the two LP fees) and all tokens are back in the pool.
        assertEq(delta.amount0(), -int256(tokenBalance));
        assertGt(delta.amount1(), 0);
        assertGt(quote.balanceOf(address(this)), quoteBefore);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_quote1_launchSucceedsWithStrayQuoteOnPositionManager() public {
        // The plan's TAKE_PAIR sweeps both currencies, so a stray quote balance donated to the
        // PositionManager lands on the strategy and stays inert, like stray ETH in native pools.
        MockERC20 quote = _deployQuoteToken(HIGH_QUOTE_ADDRESS);
        quote.transfer(address(POSITION_MANAGER), 1);
        InstantLaunchStrategy erc20QuoteStrategy =
            _deployStrategy(Currency.wrap(address(quote)), INITIAL_TICK, MIN_LAUNCH_TICK, MAX_INITIAL_TICK);
        MockERC20 token = _deployToken(TOTAL_SUPPLY);

        _initialize(erc20QuoteStrategy, IERC20(address(token)), TOTAL_SUPPLY, _defaultConfig());

        assertEq(quote.balanceOf(address(erc20QuoteStrategy)), 1);
        assertEq(token.balanceOf(address(erc20QuoteStrategy)), 0);
    }

    function test_erc20Quote_collectFeesRevertsWithInvalidBaseCurrency() public {
        // The FeeSplitter only collects native-currency0 positions today: an ERC20-quote launch
        // custodies its position but cannot collect fees until the splitter supports ERC20 quotes.
        (, MockERC20 token, PoolKey memory key, uint256 tokenId) = _launchWithQuote(HIGH_QUOTE_ADDRESS);

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        vm.expectRevert(
            abi.encodeWithSelector(IFeeSplitter.InvalidBaseCurrency.selector, tokenId, Currency.wrap(address(token)))
        );
        feeSplitter.collectFees(tokenIds);
    }
}
