// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @notice Gas benchmark tests for LBPStrategyBasic
/// @dev These tests are isolated to ensure accurate gas measurements
contract LBPStrategyBasicGasTest is LBPStrategyBasicTestBase {
    /// @notice Test gas consumption for onTokensReceived
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_onTokensReceived_gas() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), DEFAULT_TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.snapshotGasLastCall("onTokensReceived");
    }

    /// @notice Test gas consumption for onNotify with ETH
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_onNotify_withETH_gas() public {
        // Setup auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 ethAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Give auction ETH
        vm.deal(address(lbp.auction()), ethAmount);

        // Calculate price
        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, ethAmount);

        // Set initial price
        vm.prank(address(lbp.auction()));
        lbp.onNotify{value: ethAmount}(abi.encode(priceX192, tokenAmount, ethAmount));
        vm.snapshotGasLastCall("onNotifyWithETH");
    }

    /// @notice Test gas consumption for onNotify with non-ETH currency
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_onNotify_withNonETHCurrency_gas() public {
        // Setup with DAI
        setupWithCurrency(DAI);

        // Setup auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Setup DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        // Calculate price
        uint256 priceX192 = FullMath.mulDiv(tokenAmount, 2 ** 192, daiAmount);

        // Approve and set price
        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), 1_000e18);
        lbp.onNotify(abi.encode(priceX192, tokenAmount, daiAmount));
        vm.snapshotGasLastCall("onNotifyWithNonETHCurrency");
    }

    /// @notice Test gas consumption for migrate with ETH (full range)
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_migrate_withETH_gas() public {
        // Setup
        uint128 tokenAmount = DEFAULT_TOTAL_SUPPLY / 2;
        uint128 ethAmount = 500e18;

        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);
        onNotifyETH(lbp, tokenAmount, ethAmount);

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
        onNotifyETH(lbp, tokenAmount, ethAmount);

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

        // Give auction DAI
        deal(DAI, address(lbp.auction()), daiAmount);

        onNotifyToken(lbp, DAI, tokenAmount, daiAmount);

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

        // Give auction DAI
        deal(DAI, address(lbp.auction()), daiAmount);

        // Set initial price
        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), daiAmount);

        uint256 priceX192 = FullMath.mulDiv(daiAmount, 2 ** 192, tokenAmount);

        lbp.onNotify(abi.encode(priceX192, tokenAmount, daiAmount));
        vm.stopPrank();

        // Fast forward and migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency_withOneSidedPosition");
    }
}
