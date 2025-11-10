// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ERC20} from "@openzeppelin-latest/contracts/token/ERC20/ERC20.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {Checkpoint, ValueX7} from "continuous-clearing-auction/src/libraries/CheckpointLib.sol";
import {ICheckpointStorage} from "continuous-clearing-auction/src/interfaces/ICheckpointStorage.sol";
import {ITickStorage} from "continuous-clearing-auction/src/interfaces/ITickStorage.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract LBPStrategyBasicGasTest is LBPStrategyBasicTestBase {
    /// @notice Test gas consumption for onTokensReceived
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_onTokensReceived_gas() public {
        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), DEFAULT_TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.snapshotGasLastCall("onTokensReceived");
    }

    /// @notice Test gas consumption for migrate with ETH (full range)
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_migrate_withETH_gas() public {
        // Setup
        sendTokensToLBP(address(liquidityLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IContinuousClearingAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Step 2: Move to auction start
        vm.roll(realAuction.startBlock());

        _submitBid(
            realAuction,
            alice,
            inputAmountForTokens(500e18, tickNumberToPriceX96(2)), // 500 tokens at floor price + 1 tick
            tickNumberToPriceX96(2), // price
            tickNumberToPriceX96(1), // prev price (floor price)
            0
        );

        vm.roll(realAuction.endBlock());

        realAuction.checkpoint();

        uint256 realClearingPrice = ICheckpointStorage(address(realAuction)).clearingPrice();
        uint256 realCurrencyRaised = IContinuousClearingAuction(address(realAuction)).currencyRaised();

        assertEq(realClearingPrice, tickNumberToPriceX96(2));
        assertEq(realCurrencyRaised, inputAmountForTokens(500e18, tickNumberToPriceX96(2))); // add up all the bids

        realAuction.sweepCurrency(); // sweep the currency to the LBP contract

        vm.roll(lbp.migrationBlock());
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithETH");
    }

    /// @notice Test gas consumption for migrate with ETH (one-sided position)
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_migrate_withETH_withOneSidedPosition_gas() public {
        // Setup. Send 20% of the total supply to the auction so we can create a one-sided position in tokens.
        setupWithSupplyAndTokenSplit(DEFAULT_TOTAL_SUPPLY, 2e6, address(0));
        sendTokensToLBP(address(liquidityLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IContinuousClearingAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        uint256 targetPrice = tickNumberToPriceX96(2);

        _submitBid(
            realAuction, alice, inputAmountForTokens(200e18, targetPrice), targetPrice, tickNumberToPriceX96(1), 0
        );

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        uint256 realClearingPrice = ICheckpointStorage(address(realAuction)).clearingPrice();
        uint256 realCurrencyRaised = IContinuousClearingAuction(address(realAuction)).currencyRaised();

        assertEq(realClearingPrice, targetPrice);
        assertEq(realCurrencyRaised, inputAmountForTokens(200e18, targetPrice));

        realAuction.sweepCurrency(); // sweep the currency to the LBP contract

        vm.roll(lbp.migrationBlock());
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithETH_withOneSidedPosition");
    }

    /// @notice Test gas consumption for migrate with non-ETH currency
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_migrate_withNonETHCurrency_gas() public {
        createAuctionParamsWithCurrency(DAI);
        // Setup with DAI
        setupWithCurrency(DAI);

        // Setup for migration
        sendTokensToLBP(address(liquidityLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IContinuousClearingAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        // Submit bids with DAI
        uint256 targetPrice = tickNumberToPriceX96(2);

        uint128 daiAmount = inputAmountForTokens(500e18, targetPrice);

        // Deal DAI to bidder and approve
        deal(DAI, alice, daiAmount);
        vm.prank(alice);
        ERC20(DAI).approve(address(PERMIT2), daiAmount);
        vm.prank(alice);
        IAllowanceTransfer(PERMIT2).approve(DAI, address(realAuction), daiAmount, uint48(block.timestamp + 1000));

        // Submit bid
        _submitBidNonEth(realAuction, alice, daiAmount, targetPrice, tickNumberToPriceX96(1), 0);

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        uint256 realClearingPrice = ICheckpointStorage(address(realAuction)).clearingPrice();
        uint256 realCurrencyRaised = IContinuousClearingAuction(address(realAuction)).currencyRaised();

        assertEq(realClearingPrice, targetPrice);
        assertEq(realCurrencyRaised, inputAmountForTokens(500e18, targetPrice));

        realAuction.sweepCurrency(); // sweep the currency to the LBP contract

        vm.roll(lbp.migrationBlock());

        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency");
    }

    /// @notice Test gas consumption for migrate with non-ETH currency (one-sided position)
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_migrate_withNonETHCurrency_withOneSidedPosition_gas() public {
        // Setup with DAI and larger tick spacing
        migratorParams = createMigratorParams(
            DAI,
            500,
            20,
            8e6, // 80% of the total supply to the auction (800 tokens) to create a one-sided position in DAI
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            address(this),
            true,
            true
        );
        createAuctionParamsWithCurrency(DAI);
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        // Setup for migration
        sendTokensToLBP(address(liquidityLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        IContinuousClearingAuction realAuction = lbp.auction();
        assertFalse(address(realAuction) == address(0));

        // Move to auction start
        vm.roll(realAuction.startBlock());

        // Submit bids with high price to create one-sided position
        uint256 targetPrice = tickNumberToPriceX96(5);

        uint128 daiAmount = inputAmountForTokens(800e18, targetPrice);

        // Deal DAI to bidder and approve
        deal(DAI, alice, daiAmount);
        vm.prank(alice);
        ERC20(DAI).approve(address(PERMIT2), daiAmount);
        vm.prank(alice);
        IAllowanceTransfer(PERMIT2).approve(DAI, address(realAuction), daiAmount, uint48(block.timestamp + 1000));

        // Submit bid
        _submitBidNonEth(realAuction, alice, daiAmount, targetPrice, tickNumberToPriceX96(1), 0);

        vm.roll(realAuction.endBlock());
        realAuction.checkpoint();

        uint256 realClearingPrice = ICheckpointStorage(address(realAuction)).clearingPrice();
        uint256 realCurrencyRaised = IContinuousClearingAuction(address(realAuction)).currencyRaised();

        assertEq(realClearingPrice, targetPrice);
        assertEq(realCurrencyRaised, inputAmountForTokens(800e18, targetPrice));

        realAuction.sweepCurrency();
        vm.roll(lbp.migrationBlock());

        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency_withOneSidedPosition");
    }
}
