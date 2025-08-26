// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyBasicTestBase} from "./base/LBPStrategyBasicTestBase.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";

// Mock auction contract that transfers ETH when sweepCurrency is called
contract MockAuctionWithSweep {
    uint256 immutable ethToTransfer;
    uint64 public immutable endBlock;

    constructor(uint256 _ethToTransfer, uint64 _endBlock) {
        ethToTransfer = _ethToTransfer;
        endBlock = _endBlock;
    }

    function sweepCurrency() external {
        // Transfer ETH to the caller (LBP contract)
        (bool success,) = msg.sender.call{value: ethToTransfer}("");
        require(success, "ETH transfer failed");
    }

    function clearingPrice() external pure returns (uint256) {
        return 0; // Will be mocked separately
    }
}

// Mock auction contract that transfers ERC20 when sweepCurrency is called
contract MockAuctionWithERC20Sweep {
    address immutable tokenToTransfer;
    uint256 immutable amountToTransfer;
    uint64 public immutable endBlock;

    constructor(address _token, uint256 _amount, uint64 _endBlock) {
        tokenToTransfer = _token;
        amountToTransfer = _amount;
        endBlock = _endBlock;
    }

    function sweepCurrency() external {
        // Transfer token to the caller (LBP contract)
        ERC20(tokenToTransfer).transfer(msg.sender, amountToTransfer);
    }

    function clearingPrice() external pure returns (uint256) {
        return 0; // Will be mocked separately
    }
}

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

    /// @notice Test gas consumption for fetchPriceAndCurrencyFromAuction with ETH
    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_fetchPriceAndCurrencyFromAuction_withETH_gas() public {
        // Setup auction
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        uint128 ethAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Mock auction functions
        uint256 pricePerToken = 1 << 96; // 1:1 price
        mockAuctionClearingPrice(lbp, pricePerToken);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles sweepCurrency
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount, pastEndBlock);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching (need to re-mock after etch)
        mockAuctionClearingPrice(lbp, pricePerToken);

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
        uint256 pricePerToken = 2 << 96; // 2:1
        mockAuctionClearingPrice(lbp, pricePerToken);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles ERC20 sweepCurrency
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount, pastEndBlock);
        deal(DAI, address(lbp.auction()), daiAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching (need to re-mock after etch)
        mockAuctionClearingPrice(lbp, pricePerToken);

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

        // Set up auction with price
        uint256 pricePerToken = FullMath.mulDiv(ethAmount, 1 << 96, tokenAmount);
        mockAuctionClearingPrice(lbp, pricePerToken);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles sweepCurrency
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount, pastEndBlock);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, pricePerToken);

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
        uint256 pricePerToken = FullMath.mulDiv(ethAmount, 1 << 96, tokenAmount);
        mockAuctionClearingPrice(lbp, pricePerToken);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles sweepCurrency
        MockAuctionWithSweep mockAuction = new MockAuctionWithSweep(ethAmount, pastEndBlock);
        vm.deal(address(lbp.auction()), ethAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, pricePerToken);

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

        uint128 daiAmount = DEFAULT_TOTAL_SUPPLY / 2;

        // Setup for migration
        sendTokensToLBP(address(tokenLauncher), token, lbp, DEFAULT_TOTAL_SUPPLY);

        // Set up auction with price
        mockAuctionClearingPrice(lbp, 2 << 96); // 2:1

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles ERC20 sweepCurrency
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount, pastEndBlock);
        deal(DAI, address(lbp.auction()), daiAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, 2 << 96);

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
        uint256 pricePerToken = FullMath.mulDiv(daiAmount, 1 << 96, tokenAmount);
        mockAuctionClearingPrice(lbp, pricePerToken);

        // Use a past block for endBlock
        uint64 pastEndBlock = uint64(block.number - 1);

        // Deploy mock auction that handles ERC20 sweepCurrency
        MockAuctionWithERC20Sweep mockAuction = new MockAuctionWithERC20Sweep(DAI, daiAmount, pastEndBlock);
        deal(DAI, address(lbp.auction()), daiAmount);
        vm.etch(address(lbp.auction()), address(mockAuction).code);

        // Mock clearingPrice after etching
        mockAuctionClearingPrice(lbp, pricePerToken);

        lbp.fetchPriceAndCurrencyFromAuction();

        // Fast forward and migrate
        vm.roll(lbp.migrationBlock());
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency_withOneSidedPosition");
    }
}
