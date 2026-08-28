// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    InstantLaunchTestBase,
    MockDirectShortTransferToken,
    MockDirectSixDecimalToken
} from "../../base/InstantLaunchTestBase.sol";
import {InstantLaunchStrategy, InstantLaunchConfig} from "../../../../../src/strategies/InstantLaunchStrategy.sol";
import {IStrategy} from "../../../../../src/interfaces/IStrategy.sol";
import {IFeeSplitter} from "../../../../../src/interfaces/IFeeSplitter.sol";
import {MockERC20} from "../../../../mocks/MockERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @title InitializeDistributionTest
/// @notice BTT tests for InstantLaunchStrategy.initializeDistribution
///
/// initializeDistribution
/// ├── when the caller is not the launcher
/// │   └── it reverts with OnlyLauncher
/// ├── when configData is empty
/// │   └── it reverts with InvalidConfigData
/// ├── when configData is malformed
/// │   └── it reverts in the decode
/// ├── when the fee beneficiary is the zero address or the launcher
/// │   └── it reverts with InvalidFeeBeneficiary
/// ├── when the configuration is valid
/// │   └── it registers the beneficiary with the fee splitter
/// ├── when the strategy has no beneficiary vault
/// │   ├── it launches without registering a beneficiary
/// │   └── it still requires a valid fee beneficiary
/// ├── when the token is the quote currency
/// │   └── it reverts with TokenIsQuoteCurrency
/// ├── when either supply is not the fixed supply
/// │   └── it reverts with InvalidSupply
/// ├── when the token does not use 18 decimals
/// │   └── it reverts with InvalidTokenDecimals
/// ├── when the received token amount is not exact
/// │   └── it reverts with TokenAmountMismatch
/// ├── when the pool is already initialized
/// │   └── it reverts with PoolAlreadyInitialized
/// ├── when the launch is valid
/// │   ├── it preserves preexisting balances
/// │   ├── it opens the pool at the initial price
/// │   ├── it mints one single-sided position holding the full supply
/// │   ├── it custodies the position in the fee splitter
/// │   ├── it retains no tokens and burns only dust
/// │   └── it emits the launch events
/// ├── when the token sorts above an ERC20 quote currency
/// │   └── it launches with the token as currency1
/// └── when the token sorts below the quote currency
///     ├── it opens the quote-as-currency1 pool at the negated initial tick
///     └── it mints the quote-as-currency1 single-sided position holding the full supply
contract InitializeDistributionTest is InstantLaunchTestBase {
    using StateLibrary for IPoolManager;

    function _key(address token) internal view returns (PoolKey memory) {
        return _key(token, address(0));
    }

    /// @notice The launch pool key for `token` against `quote`, sorted by address.
    function _key(address token, address quote) internal view returns (PoolKey memory) {
        (address currency0, address currency1) = token < quote ? (token, quote) : (quote, token);
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: strategy.LP_FEE(),
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
    }

    function test_WhenCallerIsNotLauncher() public {
        vm.expectRevert(InstantLaunchStrategy.OnlyLauncher.selector);
        vm.prank(makeAddr("unauthorized"));
        strategy.initializeDistribution(address(1), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenConfigDataIsEmpty() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectRevert(InstantLaunchStrategy.InvalidConfigData.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenConfigDataIsMalformed() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectRevert();
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, hex"01", bytes32(0));
    }

    function test_fuzz_WhenFeeBeneficiaryIsInvalid(bool useLauncher) public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        token.approve(address(strategy), TOTAL_SUPPLY);
        address invalid = useLauncher ? launcher : address(0);
        vm.expectRevert(abi.encodeWithSelector(InstantLaunchStrategy.InvalidFeeBeneficiary.selector, invalid));
        strategy.initializeDistribution(
            address(token), TOTAL_SUPPLY, abi.encode(InstantLaunchConfig({feeBeneficiary: invalid})), bytes32(0)
        );
    }

    function test_WhenConfigurationIsValid_registersBeneficiaryWithFeeSplitter() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        token.approve(address(strategy), TOTAL_SUPPLY);
        // The vault mints its beneficiary NFT (same tokenId) to the configured beneficiary.
        vm.expectEmit(true, true, true, true, address(beneficiaryVault));
        emit IERC721.Transfer(address(0), launchFeeBeneficiary, tokenId);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));

        assertEq(beneficiaryVault.ownerOf(tokenId), launchFeeBeneficiary);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(feeSplitter));
    }

    function test_WhenStrategyHasNoBeneficiaryVault_launchesWithoutRegisteringBeneficiary() public {
        InstantLaunchStrategy vaultless = _deployStrategyWithoutBeneficiaryVault();
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        token.approve(address(vaultless), TOTAL_SUPPLY);
        vaultless.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));

        // No beneficiary NFT is minted, so the vault flushes this position's share to its fallbacks.
        assertEq(beneficiaryVault.balanceOf(launchFeeBeneficiary), 0);
        // The position still reaches the splitter for permanent custody.
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(feeSplitter));
    }

    function test_WhenStrategyHasNoBeneficiaryVault_stillRequiresValidFeeBeneficiary() public {
        InstantLaunchStrategy vaultless = _deployStrategyWithoutBeneficiaryVault();
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        token.approve(address(vaultless), TOTAL_SUPPLY);

        // configData encodes identically against every deployment, vault or not.
        vm.expectRevert(abi.encodeWithSelector(InstantLaunchStrategy.InvalidFeeBeneficiary.selector, address(0)));
        vaultless.initializeDistribution(
            address(token), TOTAL_SUPPLY, abi.encode(InstantLaunchConfig({feeBeneficiary: address(0)})), bytes32(0)
        );
    }

    function test_WhenTokenIsQuoteCurrency() public {
        MockERC20 quote = _deployQuoteToken(HIGH_QUOTE_ADDRESS);
        InstantLaunchStrategy erc20QuoteStrategy =
            _deployStrategy(Currency.wrap(address(quote)), INITIAL_TICK, MIN_LAUNCH_TICK, MAX_INITIAL_TICK);

        // A quote-quote pool key could never sort; the launch rejects the token before any pull.
        vm.expectRevert(InstantLaunchStrategy.TokenIsQuoteCurrency.selector);
        erc20QuoteStrategy.initializeDistribution(address(quote), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenDistributionAmountIsNotFixedSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        vm.expectRevert(InstantLaunchStrategy.InvalidSupply.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY - 1, _defaultConfig(), bytes32(0));
    }

    function test_WhenTokenSupplyIsNotFixedSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY - 1);
        vm.expectRevert(InstantLaunchStrategy.InvalidSupply.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenTokenDoesNotUse18Decimals() public {
        MockDirectSixDecimalToken token = new MockDirectSixDecimalToken(TOTAL_SUPPLY, address(this));
        vm.expectRevert(InstantLaunchStrategy.InvalidTokenDecimals.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenReceivedTokenAmountIsNotExact() public {
        MockDirectShortTransferToken token = new MockDirectShortTransferToken(TOTAL_SUPPLY, address(this));
        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(InstantLaunchStrategy.TokenAmountMismatch.selector, TOTAL_SUPPLY - 1, TOTAL_SUPPLY)
        );
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenPoolIsAlreadyInitialized() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        // Anyone can initialize the hookless pool key ahead of the launch; the launch must not
        // silently adopt the attacker's price.
        poolManager.initialize(_key(address(token)), TickMath.getSqrtPriceAtTick(0));

        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenLaunchIsValid_preservesPreexistingBalance() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        // Strand a preexisting balance on the strategy (without changing total supply); the launch's
        // dust sweep must only burn what it added, leaving the preexisting balance intact.
        deal(address(token), address(strategy), 1 ether, false);
        _initialize(token, TOTAL_SUPPLY, _defaultConfig());
        assertEq(token.balanceOf(address(strategy)), 1 ether);
    }

    function test_WhenLaunchIsValid_opensPoolAtInitialPrice() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        _initialize(token, TOTAL_SUPPLY, _defaultConfig());

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(_key(address(token)).toId());
        assertEq(sqrtPriceX96, strategy.quote0InitialSqrtPriceX96());
        assertEq(tick, INITIAL_TICK);
    }

    function test_WhenLaunchIsValid_mintsSingleSidedPositionWithFullSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();
        address recipient = address(feeSplitter);

        _initialize(token, TOTAL_SUPPLY, _defaultConfig());

        // One position, spanning the token side of the price, holding the precomputed liquidity.
        assertEq(POSITION_MANAGER.nextTokenId(), tokenId + 1);
        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        assertEq(info.tickLower(), strategy.minLaunchTick());
        assertEq(info.tickUpper(), INITIAL_TICK);
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), strategy.quote0PositionLiquidity());
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), recipient);
    }

    function test_WhenLaunchIsValid_custodiesPositionInFeeSplitter() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        _initialize(token, TOTAL_SUPPLY, _defaultConfig());

        // The singleton splitter holds the position permanently; it has no exit path for it.
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(feeSplitter));
        assertEq(address(feeSplitter.positionManager()), address(POSITION_MANAGER));
    }

    function test_WhenLaunchIsValid_retainsNoTokensAndBurnsOnlyDust() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        _initialize(token, TOTAL_SUPPLY, _defaultConfig());

        uint256 burned = token.balanceOf(address(0xdead));
        // Everything not in the pool is burned rounding dust: less than one token out of a billion.
        assertEq(token.balanceOf(address(poolManager)) + burned, TOTAL_SUPPLY);
        assertLt(burned, 1 ether);
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(positionManager)), 0);
    }

    function test_WhenLaunchIsValid_emitsLaunchEvents() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        PoolKey memory key = _key(address(token));
        address recipient = address(feeSplitter);
        token.approve(address(strategy), TOTAL_SUPPLY);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit IStrategy.DistributionInitialized(address(strategy), address(token), TOTAL_SUPPLY);
        vm.expectEmit(true, true, true, true, address(strategy));
        emit InstantLaunchStrategy.TokenLaunched(key.toId(), address(token), recipient, key);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenTokenSortsAboveErc20Quote_launchesWithTokenAsCurrency1() public {
        MockERC20 quote = _deployQuoteToken(LOW_QUOTE_ADDRESS);
        InstantLaunchStrategy erc20QuoteStrategy =
            _deployStrategy(Currency.wrap(address(quote)), INITIAL_TICK, MIN_LAUNCH_TICK, MAX_INITIAL_TICK);
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        _initialize(erc20QuoteStrategy, token, TOTAL_SUPPLY, _defaultConfig());

        // The token sorts above the quote, so the launch keeps the token-as-currency1 orientation.
        PoolKey memory key = _key(address(token), address(quote));
        assertEq(Currency.unwrap(key.currency0), address(quote));
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, erc20QuoteStrategy.quote0InitialSqrtPriceX96());
        assertEq(tick, INITIAL_TICK);

        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        assertEq(info.tickLower(), erc20QuoteStrategy.minLaunchTick());
        assertEq(info.tickUpper(), INITIAL_TICK);
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), erc20QuoteStrategy.quote0PositionLiquidity());
    }

    function test_WhenTokenSortsBelowQuote_opensQuote1PoolAtNegatedInitialTick() public {
        MockERC20 quote = _deployQuoteToken(HIGH_QUOTE_ADDRESS);
        InstantLaunchStrategy quote1Strategy =
            _deployStrategy(Currency.wrap(address(quote)), INITIAL_TICK, MIN_LAUNCH_TICK, MAX_INITIAL_TICK);
        MockERC20 token = _deployToken(TOTAL_SUPPLY);

        _initialize(quote1Strategy, token, TOTAL_SUPPLY, _defaultConfig());

        // The token sorts below the quote, so it becomes currency0 and the pool opens at the
        // negated initial tick.
        PoolKey memory key = _key(address(token), address(quote));
        assertEq(Currency.unwrap(key.currency0), address(token));
        assertEq(Currency.unwrap(key.currency1), address(quote));
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, quote1Strategy.quote1InitialSqrtPriceX96());
        assertEq(tick, -INITIAL_TICK);
    }

    function test_WhenTokenSortsBelowQuote_mintsQuote1SingleSidedPositionWithFullSupply() public {
        MockERC20 quote = _deployQuoteToken(HIGH_QUOTE_ADDRESS);
        InstantLaunchStrategy quote1Strategy =
            _deployStrategy(Currency.wrap(address(quote)), INITIAL_TICK, MIN_LAUNCH_TICK, MAX_INITIAL_TICK);
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        _initialize(quote1Strategy, token, TOTAL_SUPPLY, _defaultConfig());

        // The quote-as-currency1 single-sided range sits above the opening price: from the negated initial
        // tick up to the negated launch floor.
        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        assertEq(info.tickLower(), -INITIAL_TICK);
        assertEq(info.tickUpper(), -quote1Strategy.minLaunchTick());
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), quote1Strategy.quote1PositionLiquidity());
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(feeSplitter));

        // Whole supply accounted for: everything is in the pool except burned rounding dust.
        uint256 burned = token.balanceOf(address(0xdead));
        assertEq(token.balanceOf(address(poolManager)) + burned, TOTAL_SUPPLY);
        assertLt(burned, 1 ether);
        assertEq(token.balanceOf(address(quote1Strategy)), 0);
    }

    function test_fuzz_WhenTokenSortsBelowQuote_mintsExactQuote1Liquidity(int24 initialTick) public {
        int24 tickSpacing = strategy.TICK_SPACING();
        initialTick = int24(
            bound(initialTick, LOWEST_LAUNCH_TICK / tickSpacing, strategy.maxInitialTick() / tickSpacing)
        ) * tickSpacing;

        MockERC20 quote = _deployQuoteToken(HIGH_QUOTE_ADDRESS);
        InstantLaunchStrategy quote1Strategy =
            _deployStrategy(Currency.wrap(address(quote)), initialTick, MIN_LAUNCH_TICK, MAX_INITIAL_TICK);
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        // The launch only succeeds when the plan resolves to exactly the precomputed quote1
        // liquidity, so this covers the constructor's quote1 liquidity math across the whole tick domain.
        _initialize(quote1Strategy, token, TOTAL_SUPPLY, _defaultConfig());

        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), quote1Strategy.quote1PositionLiquidity());
        assertLt(token.balanceOf(address(0xdead)), 1 ether);
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_WhenLaunchIsValid_gas() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        token.approve(address(strategy), TOTAL_SUPPLY);

        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
        vm.snapshotGasLastCall("InstantLaunchStrategy initializeDistribution");
    }
}
