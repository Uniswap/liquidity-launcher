// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IProtocolFeeController} from "src/interfaces/IProtocolFeeController.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IERC721Balance {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice End-to-end fuzz tests exercising the full initializeDistribution → migrate flow
contract LBPStrategy_E2E_Test is LBPStrategyTestBase {
    address feeRecipient = makeAddr("feeRecipient");

    struct Erc20MigrationBalances {
        uint256 currencyFundsRecipient;
        uint256 currencyPool;
        uint256 tokenFundsRecipient;
        uint256 tokenPool;
    }

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

        uint256 currencyToFundsRecipient = fundsRecipient.balance - recipientBalBefore;
        uint256 currencyToPool = address(POOL_MANAGER).balance - poolMgrBalBefore;
        uint256 tokensToFundsRecipient = token.balanceOf(fundsRecipient) - recipientTokenBalBefore;
        uint256 tokensToPool = token.balanceOf(address(POOL_MANAGER)) - poolMgrTokenBalBefore;

        assertEq(currencyToFundsRecipient + currencyToPool, raised);
        assertEq(tokensToFundsRecipient + tokensToPool, totalSupply);
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

    function test_fuzz_allRaisedCurrencyIsSentToFundsRecipientOrPool(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();

        uint256 recipientBalBefore = fundsRecipient.balance;
        uint256 poolManagerBalBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 currencyToFundsRecipient = fundsRecipient.balance - recipientBalBefore;
        uint256 currencyToPool = address(POOL_MANAGER).balance - poolManagerBalBefore;

        assertEq(currencyToFundsRecipient + currencyToPool, lbpParams.currencyRaised);
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

        Erc20MigrationBalances memory balancesBefore = Erc20MigrationBalances({
            currencyFundsRecipient: currencyToken.balanceOf(fundsRecipient),
            currencyPool: currencyToken.balanceOf(address(POOL_MANAGER)),
            tokenFundsRecipient: token.balanceOf(fundsRecipient),
            tokenPool: token.balanceOf(address(POOL_MANAGER))
        });

        strategy.migrate(ILBPInitializer(address(initializer)));

        _assertErc20MigrationBalances(currencyToken, token, balancesBefore, p.currencyRaised, totalSupply);
        // Strategy ends empty
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    struct FeeFuzzInputs {
        uint8 tierCount;
        uint24 pips1;
        uint24 pips2;
        uint24 pips3;
        uint256 split1;
        uint256 split2;
    }

    /// @notice Full init → migrate flow with a fuzzed protocol fee schedule enabled.
    /// Proves the whole pipeline (init + fee deduction + bracket calc + LP positioning + sweep)
    /// works end-to-end with fees on, across 1/2/3-tier configurations with varying pips and thresholds.
    /// Tier-fee math correctness is exhaustively tested in protocolFee.t.sol; here we only check
    /// that no currency leaks across the integrated path.
    function test_fuzz_initAndMigrate_withProtocolFee(MigrationFuzzParams memory p, FeeFuzzInputs memory f) public {
        feeController.setProtocolFeeRecipient(feeRecipient);
        feeController.setProtocolFeePerCurrency(address(0), _buildFuzzedFeeSchedule(f));

        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        uint256 raised = initializer.lbpInitializationParams().currencyRaised;
        uint256 totalSupply = token.totalSupply();

        uint256 feeBalBefore = feeRecipient.balance;
        uint256 fundsBalBefore = fundsRecipient.balance;
        uint256 poolBalBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 feeDelta = feeRecipient.balance - feeBalBefore;
        uint256 fundsDelta = fundsRecipient.balance - fundsBalBefore;
        uint256 poolDelta = address(POOL_MANAGER).balance - poolBalBefore;

        // Every wei of raised currency lands at exactly one of (feeRecipient, fundsRecipient, pool)
        assertEq(feeDelta + fundsDelta + poolDelta, raised);
        // Tokens are not subject to the protocol fee — they split between funds and pool
        assertEq(token.balanceOf(fundsRecipient) + token.balanceOf(address(POOL_MANAGER)), totalSupply);
        // Strategy ends empty
        assertEq(address(strategy).balance, 0);
        assertEq(token.balanceOf(address(strategy)), 0);
    }

    /// @dev Builds a 1/2/3-tier fee schedule from fuzz inputs. Each tier's pips are capped at 10% so
    /// the worst-case combined fee (~30%) leaves enough post-fee currency to fund the LP across the
    /// fuzzed bracket configurations from _setupForMigration. Higher pips are exercised in protocolFee.t.sol.
    function _buildFuzzedFeeSchedule(FeeFuzzInputs memory f)
        private
        view
        returns (IProtocolFeeController.Fee[] memory)
    {
        uint8 tierCount = uint8(bound(f.tierCount, 1, 3));
        uint24 maxPips = feeController.PIPS_DENOMINATOR() / 10;

        IProtocolFeeController.Fee[] memory fees = new IProtocolFeeController.Fee[](tierCount);
        fees[0] = IProtocolFeeController.Fee({lowerThreshold: 0, protocolFeePips: uint24(bound(f.pips1, 0, maxPips))});
        if (tierCount >= 2) {
            uint256 split1 = bound(f.split1, 1, type(uint256).max - 1);
            fees[1] = IProtocolFeeController.Fee({
                lowerThreshold: split1, protocolFeePips: uint24(bound(f.pips2, 0, maxPips))
            });
            if (tierCount == 3) {
                fees[2] = IProtocolFeeController.Fee({
                    lowerThreshold: bound(f.split2, split1 + 1, type(uint256).max),
                    protocolFeePips: uint24(bound(f.pips3, 0, maxPips))
                });
            }
        }
        return fees;
    }

    function _assertErc20MigrationBalances(
        MockERC20 currencyToken,
        MockERC20 token,
        Erc20MigrationBalances memory beforeBalances,
        uint256 currencyRaised,
        uint256 totalSupply
    ) private view {
        uint256 currencyToFundsRecipient =
            currencyToken.balanceOf(fundsRecipient) - beforeBalances.currencyFundsRecipient;
        uint256 currencyToPool = currencyToken.balanceOf(address(POOL_MANAGER)) - beforeBalances.currencyPool;
        uint256 tokensToFundsRecipient = token.balanceOf(fundsRecipient) - beforeBalances.tokenFundsRecipient;
        uint256 tokensToPool = token.balanceOf(address(POOL_MANAGER)) - beforeBalances.tokenPool;

        assertEq(currencyToFundsRecipient + currencyToPool, currencyRaised);
        assertEq(tokensToFundsRecipient + tokensToPool, totalSupply);
    }
}
