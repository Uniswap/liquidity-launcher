// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IERC721Balance {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice End-to-end fuzz tests exercising the full initializeDistribution → migrate flow
contract LBPStrategy_E2E_Test is LBPStrategyTestBase {
    /// @notice Full init → migrate flow with native ETH currency:
    /// - it stores the MigratorParameters
    /// - it migrates successfully after migrationBlock
    /// - it leaves no funds in the strategy
    /// - it sends leftover currency and tokens to fundsRecipient
    function test_fuzz_initAndMigrate_happyPath(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        uint256 raised = initializer.lbpInitializationParams().currencyRaised;
        uint256 totalSupply = token.totalSupply();

        // it stores the MigratorParameters
        (MigratorParameters memory storedParams) = strategy.initializers(ILBPInitializer(address(initializer)));
        assertGt(storedParams.migrationBlock, 0);

        uint256 recipientBalBefore = fundsRecipient.balance;
        uint256 recipientTokenBalBefore = token.balanceOf(fundsRecipient);
        uint256 poolMgrBalBefore = address(POOL_MANAGER).balance;
        uint256 poolMgrTokenBalBefore = token.balanceOf(address(POOL_MANAGER));

        // it migrates successfully after migrationBlock
        strategy.migrate(ILBPInitializer(address(initializer)));

        // it leaves no funds in the strategy
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);

        // Conservation: every wei raised reaches fundsRecipient or the pool manager
        assertEq(
            (fundsRecipient.balance - recipientBalBefore) + (address(POOL_MANAGER).balance - poolMgrBalBefore), raised
        );
        // Conservation: every token issued reaches fundsRecipient or the pool manager
        assertEq(
            (token.balanceOf(fundsRecipient) - recipientTokenBalBefore)
                + (token.balanceOf(address(POOL_MANAGER)) - poolMgrTokenBalBefore),
            totalSupply
        );
    }

    function test_initAndMigrate_mintsLpPositionForStandardPlan() public {
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 5e6}); // 50% to LP

        PositionDefinition[] memory defs = new PositionDefinition[](2);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 5e6});
        defs[1] = PositionDefinition({offsetLower: -600, offsetUpper: 600, weight: 5e6});

        MigratorParameters memory mp = MigratorParameters({
            migrationBlock: uint64(block.number + 1),
            poolLPFee: 3000,
            poolTickSpacing: 60,
            supplyForLP: 100 ether,
            fundsRecipient: fundsRecipient,
            lpPositionRecipient: lpPositionRecipient,
            lpHook: address(0),
            positionDefinitions: abi.encode(defs),
            lpAllocationSchedule: new bytes(0)
        });
        uint128 totalSupply = mp.supplyForLP + 10 ether;

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, uint64(block.number), bp);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({initialPriceX96: uint160(1 << 96), tokensSold: 1 ether, currencyRaised: 100 ether})
        );

        vm.deal(address(initializer), 100 ether);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);

        uint256 nextTokenIdBefore = POSITION_MANAGER.nextTokenId();

        strategy.migrate(ILBPInitializer(address(initializer)));

        assertGt(POSITION_MANAGER.nextTokenId(), nextTokenIdBefore);
        assertGt(IERC721Balance(address(POSITION_MANAGER)).balanceOf(lpPositionRecipient), 0);
    }

    /// @notice Two independent distributions store separate migration parameters
    function test_fuzz_twoDistributionsStoreSeparateParams(MigrationFuzzParams memory p1, MigrationFuzzParams memory p2)
        public
    {
        (MigratorParameters memory mp1, uint128 totalSupply1, uint64 endBlock1,) = _boundMigratorParams(p1);
        (MigratorParameters memory mp2, uint128 totalSupply2, uint64 endBlock2,) = _boundMigratorParams(p2);

        (MockLBPInitializer init1,) = _initializeWith(mp1, totalSupply1, endBlock1, _boundBrackets(p1.bpParams));
        (MockLBPInitializer init2,) = _initializeWith(mp2, totalSupply2, endBlock2, _boundBrackets(p2.bpParams));

        (MigratorParameters memory stored1) = strategy.initializers(ILBPInitializer(address(init1)));
        (MigratorParameters memory stored2) = strategy.initializers(ILBPInitializer(address(init2)));
        assertEq(stored1.migrationBlock, mp1.migrationBlock);
        assertEq(stored2.migrationBlock, mp2.migrationBlock);
    }

    function test_fuzz_currencyConservationOnMigrate(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();

        uint256 recipientBalBefore = fundsRecipient.balance;
        uint256 poolManagerBalBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        // Every wei of currencyRaised reaches fundsRecipient or the pool manager (LP positions)
        assertEq(
            (fundsRecipient.balance - recipientBalBefore) + (address(POOL_MANAGER).balance - poolManagerBalBefore),
            lbpParams.currencyRaised
        );
        assertEq(address(strategy).balance, 0);
    }

    /// @notice E2E test with ERC20 currency (not native ETH)
    function test_fuzz_erc20Currency_initAndMigrate(MigrationFuzzParams memory p) public {
        // Deploy an ERC20 to use as currency
        MockERC20 currencyToken = new MockERC20("Currency", "CUR", type(uint128).max, address(this));
        factory.setCurrencyOverride(address(currencyToken));

        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
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

        uint256 recipientCurrencyBefore = currencyToken.balanceOf(fundsRecipient);
        uint256 poolManagerCurrencyBefore = currencyToken.balanceOf(address(POOL_MANAGER));
        uint256 recipientTokenBefore = token.balanceOf(fundsRecipient);
        uint256 poolManagerTokenBefore = token.balanceOf(address(POOL_MANAGER));

        strategy.migrate(ILBPInitializer(address(initializer)));

        // Currency conservation: every unit raised reaches fundsRecipient or the pool
        assertEq(
            (currencyToken.balanceOf(fundsRecipient) - recipientCurrencyBefore)
                + (currencyToken.balanceOf(address(POOL_MANAGER)) - poolManagerCurrencyBefore),
            p.currencyRaised
        );
        // Token conservation: every token issued reaches fundsRecipient or the pool
        assertEq(
            (token.balanceOf(fundsRecipient) - recipientTokenBefore)
                + (token.balanceOf(address(POOL_MANAGER)) - poolManagerTokenBefore),
            totalSupply
        );
        // Strategy ends empty
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }
}
