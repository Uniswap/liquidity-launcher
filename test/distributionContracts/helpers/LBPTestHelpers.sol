// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LBPStrategyBasic} from "../../../src/distributionContracts/LBPStrategyBasic.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

abstract contract LBPTestHelpers is Test {
    struct BalanceSnapshot {
        uint256 tokenInPosm;
        uint256 currencyInPosm;
        uint256 tokenInPoolm;
        uint256 currencyInPoolm;
        uint256 wethInRecipient;
    }

    function takeBalanceSnapshot(
        address token,
        address currency,
        address positionManager,
        address poolManager,
        address weth9,
        address recipient
    ) internal view returns (BalanceSnapshot memory) {
        BalanceSnapshot memory snapshot;

        snapshot.tokenInPosm = IERC20(token).balanceOf(positionManager);

        if (currency == address(0)) {
            snapshot.currencyInPosm = positionManager.balance;
            snapshot.currencyInPoolm = poolManager.balance;
        } else {
            snapshot.currencyInPosm = IERC20(currency).balanceOf(positionManager);
            snapshot.currencyInPoolm = IERC20(currency).balanceOf(poolManager);
        }

        snapshot.tokenInPoolm = IERC20(token).balanceOf(poolManager);
        snapshot.wethInRecipient = IWETH9(weth9).balanceOf(recipient);

        return snapshot;
    }

    function assertPositionCreated(
        IPositionManager positionManager,
        uint256 tokenId,
        address expectedCurrency0,
        address expectedCurrency1,
        uint24 expectedFee,
        int24 expectedTickSpacing,
        int24 expectedTickLower,
        int24 expectedTickUpper
    ) internal view {
        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);

        vm.assertEq(Currency.unwrap(poolKey.currency0), expectedCurrency0);
        vm.assertEq(Currency.unwrap(poolKey.currency1), expectedCurrency1);
        vm.assertEq(poolKey.fee, expectedFee);
        vm.assertEq(poolKey.tickSpacing, expectedTickSpacing);
        vm.assertEq(info.tickLower(), expectedTickLower);
        vm.assertEq(info.tickUpper(), expectedTickUpper);
    }

    function assertLBPStateAfterMigration(LBPStrategyBasic lbp, address token, address currency, address weth9)
        internal
        view
    {
        // Assert LBP is empty
        vm.assertEq(address(lbp).balance, 0);
        vm.assertEq(IERC20(token).balanceOf(address(lbp)), 0);
        vm.assertEq(IWETH9(weth9).balanceOf(address(lbp)), 0);

        if (currency != address(0)) {
            vm.assertEq(IERC20(currency).balanceOf(address(lbp)), 0);
        }

        // Assert auction is empty if ETH
        if (currency == address(0)) {
            vm.assertEq(address(lbp.auction()).balance, 0);
        } else {
            vm.assertEq(IERC20(currency).balanceOf(address(lbp.auction())), 0);
        }
    }

    function assertBalancesAfterMigration(BalanceSnapshot memory before, BalanceSnapshot memory afterMigration)
        internal
        pure
    {
        // should not be any leftover dust in position manager (should all be in pool manager)
        vm.assertEq(afterMigration.tokenInPosm, before.tokenInPosm);
        vm.assertEq(afterMigration.currencyInPosm, before.currencyInPosm);

        // Pool Manager should have received funds
        vm.assertGt(afterMigration.tokenInPoolm, before.tokenInPoolm);
        vm.assertGt(afterMigration.currencyInPoolm, before.currencyInPoolm);
    }

    function calculateExpectedLiquidity(
        int24 tickSpacing,
        uint128 tokenAmount,
        uint128 currencyAmount,
        uint160 sqrtPriceX96
    ) internal pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK / tickSpacing * tickSpacing),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK / tickSpacing * tickSpacing),
            tokenAmount,
            currencyAmount
        );
    }

    function sendTokensToLBP(address tokenLauncher, IERC20 token, LBPStrategyBasic lbp, uint256 amount) internal {
        vm.prank(tokenLauncher);
        token.transfer(address(lbp), amount);
        lbp.onTokensReceived();
    }

    function onNotifyETH(LBPStrategyBasic lbp, uint128 tokenAmount, uint128 ethAmount) internal {
        // Give auction ETH
        vm.deal(address(lbp.auction()), ethAmount);

        // Calculate price and set it
        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);

        vm.prank(address(lbp.auction()));
        lbp.onNotify{value: ethAmount}(abi.encode(priceX192, tokenAmount, ethAmount));
    }

    function onNotifyToken(LBPStrategyBasic lbp, address currency, uint128 tokenAmount, uint128 currencyAmount)
        internal
    {
        // Note: The calling test should have already given the auction the currency using deal()

        // Approve LBP to spend
        vm.prank(address(lbp.auction()));
        ERC20(currency).approve(address(lbp), currencyAmount);

        // Calculate price and set it
        uint256 priceX192 = FullMath.mulDiv(currencyAmount, 2 ** 192, tokenAmount);

        vm.prank(address(lbp.auction()));
        lbp.onNotify(abi.encode(priceX192, tokenAmount, currencyAmount));
    }

    function migrateToMigrationBlock(LBPStrategyBasic lbp) internal {
        vm.roll(lbp.migrationBlock());
        vm.prank(address(lbp));
        lbp.migrate();
    }
}
