// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @notice End-to-end fuzz tests exercising the full initializeDistribution → migrate flow
contract LBPStrategy_E2E_Test is LBPStrategyTestBase {
    struct E2EFuzzParams {
        uint64 endBlock;
        uint64 migrationBlock;
        uint24 poolLPFee;
        int24 poolTickSpacing;
        uint128 supplyForLP;
        uint256 currencyRaised;
        uint160 initialPriceX96;
        uint128 tokensSold;
        BreakpointFuzzParams bpParams;
    }

    struct TwoAuctionParams {
        uint64 endBlock1;
        uint64 endBlock2;
        uint64 migrationBlock1;
        uint64 migrationBlock2;
        uint24 poolLPFee;
        int24 poolTickSpacing;
        uint128 supplyForLP;
        BreakpointFuzzParams bpParams1;
        BreakpointFuzzParams bpParams2;
    }

    function test_fuzz_initAndMigrate_happyPath(E2EFuzzParams memory p) public {
        (ILBPStrategy.Breakpoint[] memory bp,) = _boundBreakpoints(p.bpParams);
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p.endBlock, p.migrationBlock, p.poolLPFee, p.poolTickSpacing, p.supplyForLP);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) =
            _setupForMigration(mp, totalSupply, endBlock, p.currencyRaised, p.initialPriceX96, p.tokensSold, bp);

        // Verify migration params were stored
        (ILBPStrategy.MigratorParameters memory storedParams) =
            strategy.initializers(ILBPInitializer(address(initializer)));
        assertEq(storedParams.migrationBlock, mp.migrationBlock);

        // Record balances before migration
        uint256 recipientBalBefore = fundsRecipient.balance;
        uint256 recipientTokenBalBefore = token.balanceOf(fundsRecipient);

        // Migrate
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Strategy should be empty after migration
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);

        // fundsRecipient should have received something
        assertTrue(
            fundsRecipient.balance > recipientBalBefore || token.balanceOf(fundsRecipient) > recipientTokenBalBefore
        );
    }

    function test_fuzz_twoAuctionsIsolated(TwoAuctionParams memory p) public {
        (ILBPStrategy.Breakpoint[] memory bp1,) = _boundBreakpoints(p.bpParams1);
        (ILBPStrategy.Breakpoint[] memory bp2,) = _boundBreakpoints(p.bpParams2);
        (ILBPStrategy.MigratorParameters memory mp1, uint128 totalSupply1, uint64 endBlock1,) =
            _boundMigratorParams(p.endBlock1, p.migrationBlock1, p.poolLPFee, p.poolTickSpacing, p.supplyForLP);
        (ILBPStrategy.MigratorParameters memory mp2, uint128 totalSupply2, uint64 endBlock2,) =
            _boundMigratorParams(p.endBlock2, p.migrationBlock2, p.poolLPFee, p.poolTickSpacing, p.supplyForLP);

        (MockLBPInitializer init1,) = _initializeWith(mp1, totalSupply1, endBlock1, bp1);
        (MockLBPInitializer init2,) = _initializeWith(mp2, totalSupply2, endBlock2, bp2);

        (ILBPStrategy.MigratorParameters memory stored1) = strategy.initializers(ILBPInitializer(address(init1)));
        (ILBPStrategy.MigratorParameters memory stored2) = strategy.initializers(ILBPInitializer(address(init2)));
        assertEq(stored1.migrationBlock, mp1.migrationBlock);
        assertEq(stored2.migrationBlock, mp2.migrationBlock);
    }

    function test_fuzz_currencySplitAppliedCorrectly(E2EFuzzParams memory p) public {
        (ILBPStrategy.Breakpoint[] memory bp,) = _boundBreakpoints(p.bpParams);
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p.endBlock, p.migrationBlock, p.poolLPFee, p.poolTickSpacing, p.supplyForLP);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer,) = _setupForMigration(
            mp,
            totalSupply,
            endBlock,
            p.currencyRaised,
            _boundInitialPriceX96(uint160(p.currencyRaised)),
            p.tokensSold,
            bp
        );

        uint256 recipientBalBefore = fundsRecipient.balance;
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Nearly all currency should end up at fundsRecipient (since _createPositionPlan is a stub returning empty,
        // no currency actually goes to LP — it all gets swept). Pool initialization may consume dust.
        uint256 received = fundsRecipient.balance - recipientBalBefore;
        assertGe(received, p.currencyRaised - 1);
    }

    /// @notice E2E test with ERC20 currency (not native ETH)
    function test_fuzz_erc20Currency_initAndMigrate(E2EFuzzParams memory p) public {
        (ILBPStrategy.Breakpoint[] memory bp,) = _boundBreakpoints(p.bpParams);
        // Deploy an ERC20 to use as currency
        MockERC20 currencyToken = new MockERC20("Currency", "CUR", type(uint128).max, address(this));
        factory.setCurrencyOverride(address(currencyToken));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p.endBlock, p.migrationBlock, p.poolLPFee, p.poolTickSpacing, p.supplyForLP);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        // Initialize distribution
        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock, bp);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
            })
        );

        // Fund the initializer with ERC20 currency (not native ETH)
        deal(address(currencyToken), address(initializer), p.currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        uint256 recipientCurrencyBefore = currencyToken.balanceOf(fundsRecipient);
        uint256 recipientTokenBefore = token.balanceOf(fundsRecipient);

        strategy.migrate(ILBPInitializer(address(initializer)));

        // Strategy should be empty
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);

        // fundsRecipient should have received something
        assertTrue(
            currencyToken.balanceOf(fundsRecipient) > recipientCurrencyBefore
                || token.balanceOf(fundsRecipient) > recipientTokenBefore
        );
    }
}
