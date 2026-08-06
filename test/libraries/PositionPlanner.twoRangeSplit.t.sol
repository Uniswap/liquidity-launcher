// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionPlanner} from "../../src/libraries/PositionPlanner.sol";
import {TickCalculations} from "../../src/libraries/TickCalculations.sol";
import {Plan, Position, PositionDefinition, CurrencyAmounts} from "../../src/types/PositionPlannerTypes.sol";
import {MockPositionPlanner} from "./PositionPlanner.t.sol";

/// @notice Pins the behavior of the "two-range split" LP plan used by graduation clients:
///         a reserve band at/above the clearing price (in token terms) with weight `w`, plus a
///         full-range leg with weight `1 - w`, where `w = 1 - r_max` and
///         `r_max = maxLpAllocationRate * soldSupply / reserve` is the largest share of the token
///         reserve the raise can ever need to pair at full range.
///
///         Orientation matches a native-currency raise: the raised currency (ETH) sorts as
///         currency0 and the launched token as currency1. The pool price is therefore
///         token-per-currency, a rising token price is a FALLING tick, and the SDK mirrors the
///         band's percent offsets onto the reciprocal price band: the band definition arrives
///         on-chain as offsets [MIN_TICK, 0] (token side, at/below the clearing tick) and the
///         full-range leg as the sentinel [MIN_TICK, MAX_TICK].
///
///         Invariants pinned here (for clearing outcomes r = pairedTokens/reserve in (0, r_max]):
///         1. The band mints ~w*R tokens single-sided; its unconsumed currency slice carries
///            forward (weights cap consumption of the ORIGINAL budgets, `resolve` deducts only
///            actual mint amounts, and the implicit full-range fallback takes the remainder).
///            Holds whenever the raise covers the band's tick-ceiled sliver (r >= ~one spacing
///            width, ~0.5% here); see the tiny-raise test for the documented under-fill regime.
///         2. The raised currency is never part of the final sweep: for every clearing outcome
///            in (0, r_max], `resolve` leaves at most wei-scale flooring dust of currency — plus,
///            at the exact fully-subscribed boundary r = r_max, a finite-range pairing correction
///            of ~5e-17 of the raise (sqrtP/sqrtUpperUsable; ~1.6e4 wei on a 300 ETH raise).
///         3. The token residual swept is ~R*(1 - w - r) — i.e. ~R*(r_max - r) when w = 1 - r_max
///            exactly — strictly less than the single-full-range baseline's R*(1 - r) whenever
///            w > 0 (the baseline residual is what burns under today's plans).
///         4. Tick-ceil subtlety: the band's upper bound at the clearing tick is tick-CEILED, so
///            with an unaligned clearing tick the band straddles the price and draws a small,
///            bounded amount of currency (at most its own weight slice of the raise) — that
///            currency is minted into the band position, not swept.
contract PositionPlannerTwoRangeSplitTest is Test {
    using TickCalculations for int24;

    uint24 internal constant MPS = 1e7;
    /// @dev MPS per percentage point: the SDK derives the band weight in whole percent
    ///      (`liquidity_percent` is an integer on the wire) and maps it to MPS.
    uint24 internal constant MPS_PER_PERCENT = MPS / 100;

    /// @dev Canonical launch pool preset mirrored from the graduation client: 0.25% fee, spacing 50.
    int24 internal constant TICK_SPACING = 50;
    uint24 internal constant FEE = 2500;

    /// @dev Token reserve paired into the LP at migration (`reservedTokenAmountForLP`), e.g. 500M tokens.
    uint128 internal constant RESERVE = 5e26;

    /// @dev Example bracket outcome: maxLpAllocationRate = 100%, soldSupply = 3e26, reserve = 5e26
    ///      => r_max = 60% (6e6 MPS) => band weight w = 40% (4e6 MPS).
    uint24 internal constant R_MAX_MPS = 6e6;

    /// @dev Aligned and unaligned clearing ticks around a realistic launch price (~1e6 tokens/ETH).
    int24 internal constant ALIGNED_TICK = 138_150;
    int24 internal constant UNALIGNED_TICK = 138_163;

    /// @dev Flooring dust `resolve` may leave on the binding (currency) side: liquidity is floored
    ///      from the budget and the amount re-quoted, losing < Q96/sqrtP wei per mint (<= 1 wei per
    ///      mint for pool prices >= 1, i.e. tick >= 0), across <= 3 mints. See `_currencySweepDust`
    ///      for the full bound including the exact-r_max boundary term.
    uint256 internal constant CURRENCY_SWEEP_DUST_WEI = 10;

    MockPositionPlanner internal planner;

    function setUp() public {
        planner = new MockPositionPlanner();
    }

    // --- helpers -------------------------------------------------------------------------------

    /// @notice Band weight in MPS as the SDK/graduation client derives it from r_max:
    ///         bandPercent = 100 - ceil(100 * r_max), floored to a whole percent.
    function _bandWeightMps(uint24 rMaxMps) internal pure returns (uint24) {
        uint256 rMaxPercentCeil = (uint256(rMaxMps) * 100 + MPS - 1) / MPS;
        return uint24((100 - rMaxPercentCeil) * MPS_PER_PERCENT);
    }

    /// @notice The two PositionDefinitions the SDK emits for the two-range plan (native raise,
    ///         currency = currency0): band [MIN_TICK, 0] with weight w, full range with 1 - w.
    ///         `overridePositionRecipient = address(0)` on both: defer to the default recipient.
    function _twoRangeDefs(uint24 bandWeightMps) internal pure returns (PositionDefinition[] memory defs) {
        defs = new PositionDefinition[](2);
        defs[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK, offsetUpper: 0, weight: bandWeightMps, overridePositionRecipient: address(0)
        });
        defs[1] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK,
            offsetUpper: TickMath.MAX_TICK,
            weight: MPS - bandWeightMps,
            overridePositionRecipient: address(0)
        });
    }

    /// @notice Today's baseline: a single explicit full-range position with 100% weight.
    function _fullRangeDefs() internal pure returns (PositionDefinition[] memory defs) {
        defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK,
            offsetUpper: TickMath.MAX_TICK,
            weight: MPS,
            overridePositionRecipient: address(0)
        });
    }

    /// @notice Currency amount whose full-range pairing consumes `tokenEquivalent` tokens at
    ///         `sqrtPriceX96` (price = token1-per-currency0): C = T * Q192 / sqrtP^2, floored so
    ///         the clearing outcome never exceeds the intended r.
    function _currencyForTokenEquivalent(uint256 tokenEquivalent, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256)
    {
        return FullMath.mulDiv(
            FullMath.mulDiv(tokenEquivalent, FixedPoint96.Q96, sqrtPriceX96), FixedPoint96.Q96, sqrtPriceX96
        );
    }

    /// @notice Token-equivalent of a currency amount at `sqrtPriceX96` (rounded up).
    function _tokensForCurrency(uint256 currencyAmount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(
            FullMath.mulDivRoundingUp(currencyAmount, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96
        );
    }

    /// @notice Resolves the two-range plan for a clearing outcome r (in MPS of the reserve).
    /// @return positions The resolved positions (band first: definitions are processed in order)
    /// @return remaining The unconsumed budgets — exactly what `toPlan`'s final TAKE_PAIR sweeps
    /// @return currencyBudget The currency budget C derived from r
    function _resolveTwoRange(uint24 bandWeightMps, uint24 rMps, int24 clearingTick)
        internal
        view
        returns (Position[] memory positions, CurrencyAmounts memory remaining, uint256 currencyBudget)
    {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(clearingTick);
        currencyBudget = _currencyForTokenEquivalent(uint256(rMps) * RESERVE / MPS, sqrtPriceX96);
        (positions, remaining) = planner.resolve(
            _twoRangeDefs(bandWeightMps),
            sqrtPriceX96,
            TICK_SPACING,
            CurrencyAmounts({amount0: currencyBudget, amount1: RESERVE})
        );
    }

    // --- invariant 1: the band mints ~w*R tokens single-sided ----------------------------------

    function test_twoRangeSplit_alignedClearingTick_bandIsSingleSidedTokenOnly() public view {
        uint24 w = _bandWeightMps(R_MAX_MPS);
        assertEq(w, 4e6, "example: r_max 60% => band weight 40%");

        (Position[] memory positions, CurrencyAmounts memory remaining,) =
            _resolveTwoRange(w, R_MAX_MPS / 2, ALIGNED_TICK);

        // Band + explicit full-range leg + implicit full-range fallback.
        assertEq(positions.length, 3, "band + full-range leg + implicit fallback");

        // Definitions resolve in order: positions[0] is the band. With a spacing-aligned clearing
        // tick the tick-ceiled upper bound IS the clearing tick, so the band sits entirely at/below
        // the current price and is single-sided in tokens.
        Position memory band = positions[0];
        assertEq(band.tickUpper, ALIGNED_TICK, "band upper bound = clearing tick when aligned");
        assertEq(
            band.tickLower,
            (ALIGNED_TICK + TickMath.MIN_TICK).tickFloor(TICK_SPACING),
            "band lower = clearing tick + MIN_TICK offset, snapped"
        );
        assertEq(band.amount0, 0, "aligned band draws zero raised currency");

        // The band consumes (essentially) its entire w-slice of the token reserve, single-sided.
        uint256 wSlice = uint256(w) * RESERVE / MPS;
        assertLe(band.amount1, wSlice, "band token draw capped by its weight slice");
        assertGe(band.amount1, wSlice - wSlice / 1e12, "band consumes ~its whole token slice");

        // The two full-range positions sit on the usable-range boundaries.
        for (uint256 i = 1; i < 3; i++) {
            assertEq(positions[i].tickLower, TickMath.minUsableTick(TICK_SPACING));
            assertEq(positions[i].tickUpper, TickMath.maxUsableTick(TICK_SPACING));
        }

        // Invariant 2 at this outcome: nothing but wei-dust of currency survives to the sweep.
        assertLe(remaining.amount0, CURRENCY_SWEEP_DUST_WEI, "no raised currency left for the sweep");
    }

    // --- invariant 4: unaligned clearing tick => bounded, minted (not swept) currency draw ------

    function test_twoRangeSplit_unalignedClearingTick_bandCurrencyDrawBoundedAndMinted() public view {
        uint24 w = _bandWeightMps(R_MAX_MPS);
        uint24 rMps = R_MAX_MPS / 2;

        (Position[] memory positions, CurrencyAmounts memory remaining, uint256 currencyBudget) =
            _resolveTwoRange(w, rMps, UNALIGNED_TICK);

        assertEq(positions.length, 3, "band + full-range leg + implicit fallback");
        Position memory band = positions[0];

        // The band's upper bound is tick-CEILED above the unaligned clearing tick, so the band
        // straddles the price by less than one spacing width and draws some raised currency.
        assertEq(band.tickUpper, UNALIGNED_TICK.tickCeil(TICK_SPACING), "band upper tick-ceiled above clearing tick");
        assertGt(band.tickUpper, UNALIGNED_TICK, "ceiled bound straddles the clearing price");
        assertGt(band.amount0, 0, "unaligned band draws a nonzero currency amount");

        // The draw is bounded by the band's own weight slice of the raise, and it is minted into
        // the position — invariant 2 below shows it is not swept.
        assertLe(band.amount0, uint256(w) * currencyBudget / MPS, "band currency draw capped by its weight slice");

        // Away from the tiny-raise regime the token side still binds the band's liquidity, so the
        // band still consumes ~its whole token slice (invariant 1 with tolerance for the straddle).
        uint256 wSlice = uint256(w) * RESERVE / MPS;
        assertLe(band.amount1, wSlice);
        assertGe(band.amount1, wSlice - wSlice / 1e12, "token side binds: band still mints ~w*R tokens");

        assertLe(remaining.amount0, CURRENCY_SWEEP_DUST_WEI, "band's currency draw is minted, not swept");
    }

    // --- invariants 2 + 3 across the sweep of clearing outcomes ---------------------------------

    /// @notice r near zero, mid, near r_max, and exactly r_max (the flat fully-subscribed
    ///         extreme where the raise needs the full r_max share of the reserve), on both an
    ///         aligned and an unaligned clearing tick.
    function test_twoRangeSplit_sweepAcrossClearingOutcomes() public view {
        uint24 w = _bandWeightMps(R_MAX_MPS);
        uint24[4] memory rValues = [uint24(R_MAX_MPS / 1000), R_MAX_MPS / 2, R_MAX_MPS - R_MAX_MPS / 100, R_MAX_MPS];
        int24[2] memory ticks = [ALIGNED_TICK, UNALIGNED_TICK];

        for (uint256 t = 0; t < ticks.length; t++) {
            for (uint256 i = 0; i < rValues.length; i++) {
                uint24 rMps = rValues[i];
                (Position[] memory positions, CurrencyAmounts memory remaining, uint256 currencyBudget) =
                    _resolveTwoRange(w, rMps, ticks[t]);

                // Invariant 2: the raised currency is (dust aside) never part of the final sweep.
                // At r = r_max exactly, the dust includes the finite-range pairing correction —
                // ~5e-17 of the raise (see `_currencySweepDust`); below r_max it is wei-flooring only.
                assertLe(
                    remaining.amount0,
                    _currencySweepDust(currencyBudget, TickMath.getSqrtPriceAtTick(ticks[t])),
                    "raised currency must never be swept"
                );

                // Invariant 3: the token residual is ~R*(1 - w - r) whenever the raise covers the
                // band's tick-ceiled sliver (see the tiny-raise test for the under-fill regime
                // below ~one spacing width, where only the one-sided safety bounds apply).
                if (rMps >= MPS / 50) {
                    _assertTokenResidualBounds(positions, remaining, w, rMps, ticks[t]);
                } else {
                    uint256 tokenEquivalent = uint256(rMps) * RESERVE / MPS;
                    assertGe(
                        remaining.amount1 + _pairingSlack(TickMath.getSqrtPriceAtTick(ticks[t])),
                        RESERVE - uint256(w) * RESERVE / MPS - tokenEquivalent,
                        "residual never below R*(1 - w - r)"
                    );
                    assertLe(remaining.amount1, RESERVE - tokenEquivalent + 10, "residual never above baseline");
                }

                // Accounting identity: consumed + remaining == budgets (nothing lost or created).
                uint256 consumed0;
                uint256 consumed1;
                for (uint256 p = 0; p < positions.length; p++) {
                    consumed0 += positions[p].amount0;
                    consumed1 += positions[p].amount1;
                }
                assertEq(consumed0 + remaining.amount0, currencyBudget, "currency accounted for");
                assertEq(consumed1 + remaining.amount1, RESERVE, "tokens accounted for");
            }
        }
    }

    /// @notice Upper bound on the raised currency `resolve` can leave for the sweep: wei-level
    ///         flooring dust plus the finite-range pairing correction. A full-range mint pairs
    ///         amount1/amount0 slightly ABOVE the spot price (by a factor 1/(1 - sqrtP/sqrtUpper)),
    ///         so at the exact fully-subscribed boundary r = r_max the reserve remainder falls
    ///         short of pairing the whole raise by ~T * sqrtP/sqrtUpper tokens and the equivalent
    ///         ~C * sqrtP/sqrtUpper wei of currency (relative ~5e-17 here, e.g. ~1.6e4 wei on a
    ///         300 ETH raise) survives to the sweep. Doubled for safety.
    function _currencySweepDust(uint256 currencyBudget, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(TICK_SPACING));
        return 2 * FullMath.mulDiv(currencyBudget, sqrtPriceX96, sqrtUpperX96) + CURRENCY_SWEEP_DUST_WEI;
    }

    /// @dev Tokens the currency legs may pair beyond the spot-price token-equivalent of the raise:
    ///      a full-range mint pairs amount1/amount0 = price / (1 - sqrtP/sqrtUpper), slightly above
    ///      the spot price because the upper bound is finite, so the currency legs can consume up
    ///      to ~T * sqrtP/sqrtUpper extra tokens (T <= RESERVE). Doubled for safety, plus round-up wei.
    function _pairingSlack(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(TICK_SPACING));
        return 2 * FullMath.mulDiv(RESERVE, sqrtPriceX96, sqrtUpperX96) + 10;
    }

    /// @dev remaining.amount1 in [R - wSlice - T - pairingSlack, R - wSlice - T + slack] where
    ///      T = r*R/MPS is the token-equivalent of the raise, pairingSlack covers the finite-range
    ///      pairing correction (see `_pairingSlack`), and slack covers the band's straddle draw
    ///      (its currency draw un-pairs the same value of tokens) plus per-mint flooring dust.
    function _assertTokenResidualBounds(
        Position[] memory positions,
        CurrencyAmounts memory remaining,
        uint24 bandWeightMps,
        uint24 rMps,
        int24 clearingTick
    ) internal pure {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(clearingTick);
        uint256 wSlice = uint256(bandWeightMps) * RESERVE / MPS;
        uint256 tokenEquivalent = uint256(rMps) * RESERVE / MPS;
        uint256 expected = RESERVE - wSlice - tokenEquivalent;

        assertGe(remaining.amount1 + _pairingSlack(sqrtPriceX96), expected, "token residual below R*(1 - w - r)");

        // Unconsumed currency (band straddle draw and sweep dust) un-pairs its token equivalent,
        // and each wei of it can be worth ~price tokens; account both at the exact exchange rate.
        uint256 straddleSlack = _tokensForCurrency(positions[0].amount0, sqrtPriceX96);
        uint256 unpairedSlack = _tokensForCurrency(remaining.amount0 + 2, sqrtPriceX96);
        uint256 mintDust = 3 * (uint256(sqrtPriceX96) / FixedPoint96.Q96 + 1) + wSlice / 1e12 + 10;
        assertLe(
            remaining.amount1,
            expected + straddleSlack + unpairedSlack + mintDust,
            "token residual above R*(1 - w - r) + slack"
        );
    }

    // --- invariant 3 baseline: today's single full-range plan sweeps (burns) R*(1 - r) ----------

    function test_twoRangeSplit_baselineSingleFullRange_sweepsUnpairedReserve() public view {
        uint24 rMps = R_MAX_MPS / 2; // r = 30%
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(ALIGNED_TICK);
        uint256 tokenEquivalent = uint256(rMps) * RESERVE / MPS;
        uint256 currencyBudget = _currencyForTokenEquivalent(tokenEquivalent, sqrtPriceX96);

        (Position[] memory positions, CurrencyAmounts memory remaining) = planner.resolve(
            _fullRangeDefs(), sqrtPriceX96, TICK_SPACING, CurrencyAmounts({amount0: currencyBudget, amount1: RESERVE})
        );

        // A single full-range position: the explicit definition takes the whole budget, so the
        // implicit fallback has nothing left to mint.
        assertEq(positions.length, 1, "single full-range position");
        assertLe(remaining.amount0, CURRENCY_SWEEP_DUST_WEI, "baseline also never sweeps currency");

        // The baseline sweeps ~R*(1 - r) tokens: under `burnUnsoldOnFailure`-style recipients this
        // is the share of the reserve that burns today.
        uint256 expected = RESERVE - tokenEquivalent;
        assertGe(remaining.amount1 + _pairingSlack(sqrtPriceX96), expected, "baseline residual below R*(1 - r)");
        assertLe(
            remaining.amount1,
            expected + _tokensForCurrency(remaining.amount0 + 2, sqrtPriceX96) + 3
                * (uint256(sqrtPriceX96) / FixedPoint96.Q96 + 1) + 10,
            "baseline residual above R*(1 - r) + dust"
        );

        // The split strictly reduces the swept (burned) token residual by ~w*R.
        (, CurrencyAmounts memory remainingSplit,) = _resolveTwoRange(_bandWeightMps(R_MAX_MPS), rMps, ALIGNED_TICK);
        uint256 wSlice = uint256(_bandWeightMps(R_MAX_MPS)) * RESERVE / MPS;
        assertLt(remainingSplit.amount1, remaining.amount1, "split sweeps strictly less than the baseline");
        assertGe(
            remaining.amount1 - remainingSplit.amount1 + _pairingSlack(sqrtPriceX96) + wSlice / 1e9,
            wSlice,
            "split saves ~w*R tokens from the baseline sweep"
        );
    }

    // --- documented boundary: tiny raise + unaligned tick => band under-fills, still safe -------

    /// @notice When the raise is smaller than the band's one-spacing straddle sliver can absorb
    ///         (r below ~one spacing width, ~0.5%), the band's currency slice — not its token
    ///         slice — binds its liquidity: the band consumes its whole currency slice and mints
    ///         FEWER than w*R tokens. Invariant 1's "~w*R" only holds above that threshold. The
    ///         safety invariants are unaffected: no currency is swept, and the token residual is
    ///         never worse than the single-full-range baseline.
    function test_twoRangeSplit_tinyRaiseUnaligned_bandUnderfillsButStaysSafe() public view {
        uint24 w = _bandWeightMps(R_MAX_MPS);
        uint24 rMps = 1000; // r = 0.01% of the reserve — far below the ~0.5% sliver threshold

        (Position[] memory positions, CurrencyAmounts memory remaining, uint256 currencyBudget) =
            _resolveTwoRange(w, rMps, UNALIGNED_TICK);

        Position memory band = positions[0];
        uint256 wSlice = uint256(w) * RESERVE / MPS;

        // The band under-fills its token slice: the raise cannot fill the tick-ceiled sliver.
        assertLt(band.amount1, wSlice / 2, "band token draw collapses when the raise is tiny");
        // Its currency draw is still capped by its weight slice of the (tiny) raise.
        assertLe(band.amount0, uint256(w) * currencyBudget / MPS + 1, "band currency draw capped by its slice");

        // Safety invariants hold regardless.
        assertLe(remaining.amount0, CURRENCY_SWEEP_DUST_WEI, "still no raised currency in the sweep");
        uint256 tokenEquivalent = uint256(rMps) * RESERVE / MPS;
        assertGe(
            remaining.amount1 + _pairingSlack(TickMath.getSqrtPriceAtTick(UNALIGNED_TICK)),
            RESERVE - wSlice - tokenEquivalent,
            "residual never below R*(1 - w - r)"
        );
        assertLe(remaining.amount1, RESERVE - tokenEquivalent + 10, "residual never above the baseline R*(1 - r)");
    }

    // --- plan shape: the residual leaves via a single terminal TAKE_PAIR ------------------------

    function test_twoRangeSplit_toPlan_singleTerminalSweep() public view {
        address dustRecipient = address(0xD057);
        (Position[] memory positions,,) = _resolveTwoRange(_bandWeightMps(R_MAX_MPS), R_MAX_MPS / 2, UNALIGNED_TICK);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        Plan memory plan = planner.toPlan(positions, poolKey, dustRecipient);

        // MINT per position, then exactly one SETTLE per currency and ONE terminal TAKE_PAIR:
        // both leftovers (token residual + currency dust) exit in a single sweep at the end.
        assertEq(plan.actions.length, positions.length + 3);
        for (uint256 i = 0; i < positions.length; i++) {
            assertEq(uint8(plan.actions[i]), uint8(Actions.MINT_POSITION));
        }
        assertEq(uint8(plan.actions[positions.length]), uint8(Actions.SETTLE));
        assertEq(uint8(plan.actions[positions.length + 1]), uint8(Actions.SETTLE));
        assertEq(uint8(plan.actions[positions.length + 2]), uint8(Actions.TAKE_PAIR));
        (Currency c0, Currency c1, address sweepRecipient) =
            abi.decode(plan.params[positions.length + 2], (Currency, Currency, address));
        assertEq(Currency.unwrap(c0), Currency.unwrap(poolKey.currency0));
        assertEq(Currency.unwrap(c1), Currency.unwrap(poolKey.currency1));
        assertEq(sweepRecipient, dustRecipient);
    }

    // --- fuzz: invariant 2 over the whole safe region -------------------------------------------

    /// @notice For any r_max in [1%, 99%], any clearing outcome r in (0, r_max], and any clearing
    ///         tick with price >= 1 token/currency (tick >= 0, aligned or not): the raised
    ///         currency never survives to the final sweep beyond wei-dust.
    function test_fuzz_twoRangeSplit_noCurrencyLeftForSweep(uint24 rMaxMps, uint24 rMps, int24 clearingTick)
        public
        view
    {
        rMaxMps = uint24(bound(rMaxMps, MPS_PER_PERCENT, uint24(99) * MPS_PER_PERCENT));
        rMps = uint24(bound(rMps, 1, rMaxMps));
        clearingTick = int24(bound(clearingTick, 0, 300_000));
        uint24 w = _bandWeightMps(rMaxMps);
        assertGt(w, 0, "safe region always leaves a positive band weight");

        (, CurrencyAmounts memory remaining, uint256 currencyBudget) = _resolveTwoRange(w, rMps, clearingTick);
        vm.assume(currencyBudget > 0);

        // Wei-flooring dust plus, at the exact r = r_max boundary, the finite-range pairing
        // correction (~5e-17 of the raise) — economically zero either way.
        assertLe(
            remaining.amount0,
            _currencySweepDust(currencyBudget, TickMath.getSqrtPriceAtTick(clearingTick)),
            "raised currency must never be swept"
        );
    }

    // --- fuzz: invariants 1 + 3 away from the sliver threshold ----------------------------------

    /// @notice For r in [2%, r_max] (above the one-spacing sliver threshold) the band always mints
    ///         ~w*R tokens and the swept token residual is ~R*(1 - w - r), never worse than the
    ///         single-full-range baseline's ~R*(1 - r).
    function test_fuzz_twoRangeSplit_bandFillAndResidual(uint24 rMaxMps, uint24 rMps, int24 clearingTick) public view {
        rMaxMps = uint24(bound(rMaxMps, 2 * MPS_PER_PERCENT, uint24(99) * MPS_PER_PERCENT));
        rMps = uint24(bound(rMps, 2 * MPS_PER_PERCENT, rMaxMps));
        clearingTick = int24(bound(clearingTick, 0, 300_000));
        uint24 w = _bandWeightMps(rMaxMps);

        (Position[] memory positions, CurrencyAmounts memory remaining,) = _resolveTwoRange(w, rMps, clearingTick);

        // Invariant 1: the band (positions[0]) mints ~w*R tokens.
        uint256 wSlice = uint256(w) * RESERVE / MPS;
        assertLe(positions[0].amount1, wSlice, "band token draw capped by its weight slice");
        assertGe(positions[0].amount1, wSlice - wSlice / 1e9 - 10, "band consumes ~its whole token slice");

        // Invariant 3: residual ~R*(1 - w - r), and never above the baseline's ~R*(1 - r).
        _assertTokenResidualBounds(positions, remaining, w, rMps, clearingTick);
        uint256 tokenEquivalent = uint256(rMps) * RESERVE / MPS;
        assertLe(remaining.amount1, RESERVE - tokenEquivalent + 10, "residual never above the baseline R*(1 - r)");
    }
}
