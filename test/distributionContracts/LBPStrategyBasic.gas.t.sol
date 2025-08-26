// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";

/// @notice Gas benchmark tests for LBPStrategyBasic
/// @dev These tests are isolated to ensure accurate gas measurements
contract LBPStrategyBasicGasTest is LBPStrategyBasicTestBase {
    // Helper function to mock endBlock
    function mockEndBlock(uint64 blockNumber) internal {
        vm.mockCall(address(lbp.auction()), abi.encodeWithSignature("endBlock()"), abi.encode(blockNumber));
    }
    /// @notice Test gas consumption for onTokensReceived
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true

    function test_onTokensReceived_gas() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), DEFAULT_TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.snapshotGasLastCall("onTokensReceived");
    }

    /// @notice Test gas consumption for fetchPriceAndCurrencyFromAuction with ETH
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_fetchPriceAndCurrencyFromAuction_withETH_gas() public {
        // Setup auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 ethAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Mock auction functions
        uint256 pricePerToken = 1e18; // 1 ETH per token
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockEndBlock(uint64(block.number - 1)); // Mock past block so auction is ended

        // Mock sweepCurrency to transfer ETH
        vm.mockCall(address(lbp.auction()), abi.encodeWithSignature("sweepCurrency()"), "");

        // Set up ETH transfer expectation
        vm.deal(address(lbp.auction()), ethAmount);
        vm.prank(address(lbp.auction()));
        (bool success,) = address(lbp).call{value: ethAmount}("");
        require(success, "ETH transfer failed");

        // Call fetchPriceAndCurrencyFromAuction
        lbp.fetchPriceAndCurrencyFromAuction();
        vm.snapshotGasLastCall("fetchPriceAndCurrencyFromAuction_withETH");
    }

    /// @notice Test gas consumption for fetchPriceAndCurrencyFromAuction with non-ETH currency
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_fetchPriceAndCurrencyFromAuction_withNonETHCurrency_gas() public {
        // Setup with DAI
        setupWithCurrency(DAI);

        // Setup auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Mock auction functions
        uint256 pricePerToken = 1e18; // 1 DAI per token
        mockAuctionClearingPrice(lbp, pricePerToken);
        mockEndBlock(uint64(block.number - 1));

        // Mock sweepCurrency
        vm.mockCall(address(lbp.auction()), abi.encodeWithSignature("sweepCurrency()"), "");

        // Transfer DAI from auction to LBP to simulate sweepCurrency
        deal(DAI, address(lbp.auction()), daiAmount);
        vm.prank(address(lbp.auction()));
        ERC20(DAI).transfer(address(lbp), daiAmount);

        // Call fetchPriceAndCurrencyFromAuction
        lbp.fetchPriceAndCurrencyFromAuction();
        vm.snapshotGasLastCall("fetchPriceAndCurrencyFromAuction_withNonETHCurrency");
    }

    /// @notice Test gas consumption for migrate with ETH (full range)
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_migrate_withETH_gas() public {
        // Setup
        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 ethAmount = 500e18;

        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Set up auction with price and currency
        setupAuctionWithPriceAndCurrency(lbp, 1e18, ethAmount);
        lbp.fetchPriceAndCurrencyFromAuction();

        // Fast forward and migrate
        vm.roll(lbp.migrationBlock());
        vm.prank(address(lbp));
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithETH");
    }

    /// @notice Test gas consumption for migrate with ETH (one-sided position)
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_migrate_withETH_withOneSidedPosition_gas() public {
        // Setup
        uint128 ethAmount = 500e18;
        uint128 tokenAmount = lbp.reserveSupply() / 2;

        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Set up auction with price that will create one-sided position
        uint256 pricePerToken = FullMath.mulDiv(ethAmount, 1e18, tokenAmount);
        setupAuctionWithPriceAndCurrency(lbp, pricePerToken, ethAmount);
        lbp.fetchPriceAndCurrencyFromAuction();

        // Fast forward and migrate
        vm.roll(lbp.migrationBlock());
        vm.prank(address(lbp));
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithETH_withOneSidedPosition");
    }

    /// @notice Test gas consumption for migrate with non-ETH currency
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_migrate_withNonETHCurrency_gas() public {
        // Setup with DAI
        setupWithCurrency(DAI);

        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Setup for migration
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Set up auction with price and currency
        setupAuctionWithPriceAndCurrency(lbp, 1e18, daiAmount);
        lbp.fetchPriceAndCurrencyFromAuction();

        // Fast forward and migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency");
    }

    /// @notice Test gas consumption for migrate with non-ETH currency (one-sided position)
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_migrate_withNonETHCurrency_withOneSidedPosition_gas() public {
        // Setup with DAI and larger tick spacing
        migratorParams = createMigratorParams(DAI, 500, 20, DEFAULT_TOKEN_SPLIT, address(3));
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 tokenAmount = lbp.reserveSupply() / 2;

        // Setup for migration
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Set up auction with price that will create one-sided position
        uint256 pricePerToken = FullMath.mulDiv(daiAmount, 1e18, tokenAmount);
        setupAuctionWithPriceAndCurrency(lbp, pricePerToken, daiAmount);
        lbp.fetchPriceAndCurrencyFromAuction();

        // Fast forward and migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency_withOneSidedPosition");
    }
}
