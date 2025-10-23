// SPDX-License-Identifier: MIT
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
import {IERC20} from "@openzeppelin-latest/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin-latest/contracts/token/ERC20/ERC20.sol";
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";
import {ICheckpointStorage} from "twap-auction/src/interfaces/ICheckpointStorage.sol";
import {Checkpoint, ValueX7} from "twap-auction/src/libraries/CheckpointLib.sol";

abstract contract LBPTestHelpers is Test {
    struct BalanceSnapshot {
        uint256 tokenInPosm;
        uint256 currencyInPosm;
        uint256 tokenInPoolm;
        uint256 currencyInPoolm;
        uint256 wethInRecipient;
    }

    uint256 constant DUST_AMOUNT = 1e18;

    function takeBalanceSnapshot(address token, address currency, address positionManager, address poolManager, address)
        internal
        view
        returns (BalanceSnapshot memory)
    {
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

    function assertPositionNotCreated(IPositionManager positionManager, uint256 tokenId) internal view {
        (PoolKey memory poolKey, PositionInfo info) = positionManager.getPoolAndPositionInfo(tokenId);

        vm.assertEq(Currency.unwrap(poolKey.currency0), address(0));
        vm.assertEq(Currency.unwrap(poolKey.currency1), address(0));
        vm.assertEq(poolKey.fee, 0);
        vm.assertEq(poolKey.tickSpacing, 0);
        vm.assertEq(info.tickLower(), 0);
        vm.assertEq(info.tickUpper(), 0);
    }

    function assertLBPStateAfterMigration(LBPStrategyBasic lbp, address token, address currency) internal view {
        // Assert LBP is empty (with dust)
        vm.assertLe(address(lbp).balance, DUST_AMOUNT);
        vm.assertLe(IERC20(token).balanceOf(address(lbp)), DUST_AMOUNT);

        if (currency != address(0)) {
            vm.assertLe(IERC20(currency).balanceOf(address(lbp)), DUST_AMOUNT);
        }
    }

    function assertBalancesAfterMigration(BalanceSnapshot memory before, BalanceSnapshot memory afterMigration)
        internal
        pure
    {
        // should not be any leftover dust in position manager (should have been swept back)
        vm.assertEq(afterMigration.tokenInPosm, before.tokenInPosm);
        vm.assertEq(afterMigration.currencyInPosm, before.currencyInPosm);

        // Pool Manager should have received funds
        vm.assertGt(afterMigration.tokenInPoolm, before.tokenInPoolm);
        vm.assertGt(afterMigration.currencyInPoolm, before.currencyInPoolm);
    }

    function sendTokensToLBP(address tokenLauncher, IERC20 token, LBPStrategyBasic lbp, uint256 amount) internal {
        vm.prank(tokenLauncher);
        token.transfer(address(lbp), amount);
        lbp.onTokensReceived();
    }

    function mockAuctionClearingPrice(LBPStrategyBasic lbp, uint256 price) internal {
        // Mock the auction's clearingPrice function
        vm.mockCall(
            address(lbp.auction()), abi.encodeWithSelector(ICheckpointStorage.clearingPrice.selector), abi.encode(price)
        );
    }

    function mockCurrencyRaised(LBPStrategyBasic lbp, uint256 amount) internal {
        // Mock the auction's currencyRaised function
        vm.mockCall(
            address(lbp.auction()),
            abi.encodeWithSelector(ICheckpointStorage.currencyRaised.selector),
            abi.encode(amount)
        );
    }

    function mockAuctionEndBlock(LBPStrategyBasic lbp, uint64 blockNumber) internal {
        // Mock the auction's endBlock function
        vm.mockCall(address(lbp.auction()), abi.encodeWithSignature("endBlock()"), abi.encode(blockNumber));
    }

    function mockAuctionCheckpoint(LBPStrategyBasic lbp, Checkpoint memory checkpoint) internal {
        // Mock the auction's checkpoint function
        vm.mockCall(address(lbp.auction()), abi.encodeWithSignature("checkpoint()"), abi.encode(checkpoint));
    }
}
