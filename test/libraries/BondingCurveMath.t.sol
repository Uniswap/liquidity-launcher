// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BondingCurveMath} from "../../src/libraries/BondingCurveMath.sol";

contract BondingCurveMathHarness {
    function splitSupply(
        uint256 totalSupply,
        uint160 initialSqrtPriceX96,
        uint160 graduationSqrtPriceX96,
        int24 tickSpacing
    ) external pure returns (uint256 curveSupply, uint256 reserveSupply) {
        return BondingCurveMath.splitSupply(totalSupply, initialSqrtPriceX96, graduationSqrtPriceX96, tickSpacing);
    }
}

contract BondingCurveMathTest is Test {
    int24 internal constant TICK_SPACING = 200;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;

    function test_splitSupply_targetsEightyTwentyForSixteenTimesRange() public pure {
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(122_000);
        uint160 graduationSqrtPriceX96 = TickMath.getSqrtPriceAtTick(94_200);

        (uint256 curveSupply, uint256 reserveSupply) =
            BondingCurveMath.splitSupply(TOTAL_SUPPLY, initialSqrtPriceX96, graduationSqrtPriceX96, TICK_SPACING);

        assertEq(curveSupply + reserveSupply, TOTAL_SUPPLY);
        assertApproxEqRel(curveSupply, TOTAL_SUPPLY * 80 / 100, 6e15); // within 0.6%
    }

    function test_splitSupply_pairsCompletedCurveIntoFullRange() public pure {
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(122_000);
        uint160 graduationSqrtPriceX96 = TickMath.getSqrtPriceAtTick(94_200);
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        int24 maxTick = TickMath.maxUsableTick(TICK_SPACING);

        (uint256 curveSupply, uint256 reserveSupply) =
            BondingCurveMath.splitSupply(TOTAL_SUPPLY, initialSqrtPriceX96, graduationSqrtPriceX96, TICK_SPACING);
        uint128 curveLiquidity =
            LiquidityAmounts.getLiquidityForAmount1(graduationSqrtPriceX96, initialSqrtPriceX96, curveSupply);
        uint256 principal =
            BondingCurveMath.completedCurvePrincipal(curveLiquidity, graduationSqrtPriceX96, initialSqrtPriceX96);

        uint128 finalLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            graduationSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            principal,
            reserveSupply
        );
        uint256 usedCurrency = SqrtPriceMath.getAmount0Delta(
            graduationSqrtPriceX96, TickMath.getSqrtPriceAtTick(maxTick), finalLiquidity, true
        );
        uint256 usedToken = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(minTick), graduationSqrtPriceX96, finalLiquidity, true
        );

        assertApproxEqAbs(usedCurrency, principal, 2);
        assertApproxEqAbs(usedToken, reserveSupply, 2 ether);
    }

    function test_splitSupply_revertsForInvalidRange() public {
        uint160 price = TickMath.getSqrtPriceAtTick(122_000);
        BondingCurveMathHarness harness = new BondingCurveMathHarness();

        vm.expectRevert(BondingCurveMath.InvalidPriceRange.selector);
        harness.splitSupply(TOTAL_SUPPLY, price, price, TICK_SPACING);
    }
}
