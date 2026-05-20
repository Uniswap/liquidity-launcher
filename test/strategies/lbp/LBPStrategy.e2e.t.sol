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
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

interface IERC721Balance {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice End-to-end fuzz tests exercising the full initializeDistribution → migrate flow
contract LBPStrategy_E2E_Test is LBPStrategyTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

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
    /// - it sends leftover currency and tokens to leftoverRecipient
    function test_fuzz_initAndMigrate_happyPath(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);
        uint256 raised = initializer.lbpInitializationParams().currencyRaised;

        // it stores the MigratorParameters
        (MigratorParameters memory storedParams) = strategy.initializers(ILBPInitializer(address(initializer)));
        assertGt(storedParams.migrationBlock, 0);

        uint256 recipientBalBefore = leftoverRecipient.balance;
        uint256 recipientTokenBalBefore = token.balanceOf(leftoverRecipient);
        uint256 poolMgrBalBefore = address(POOL_MANAGER).balance;
        uint256 poolMgrTokenBalBefore = token.balanceOf(address(POOL_MANAGER));
        uint256 unsoldInCca = token.balanceOf(address(initializer));

        // it migrates successfully after migrationBlock
        strategy.migrate(ILBPInitializer(address(initializer)));

        // it leaves no funds in the strategy
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);

        uint256 currencyToFundsRecipient = leftoverRecipient.balance - recipientBalBefore;
        uint256 currencyToPool = address(POOL_MANAGER).balance - poolMgrBalBefore;
        uint256 tokensToFundsRecipient = token.balanceOf(leftoverRecipient) - recipientTokenBalBefore;
        uint256 tokensToPool = token.balanceOf(address(POOL_MANAGER)) - poolMgrTokenBalBefore;

        assertEq(currencyToFundsRecipient + currencyToPool, raised);
        // Only supplyForLP is distributed by the strategy. Unsold auction tokens stay in the CCA
        // for the tokensRecipient to claim separately.
        assertEq(tokensToFundsRecipient + tokensToPool, storedParams.supplyForLP);
        assertEq(token.balanceOf(address(initializer)), unsoldInCca);
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
            leftoverRecipient: leftoverRecipient,
            lpPositionRecipient: lpPositionRecipient,
            hook: address(0),
            positionDefinitions: abi.encode(defs),
            lpAllocationSchedule: new bytes(0)
        });
        uint128 totalSupply = mp.supplyForLP + 10 ether;

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: uint160(1 << 96), tokensSold: 1 ether, currencyRaised: 100 ether
        });
        (MockLBPInitializer initializer,) =
            _initializeWith(mp, totalSupply, uint64(block.number), bp, address(0), lbpParams);

        vm.deal(address(initializer), 100 ether);
        vm.roll(mp.migrationBlock);

        uint256 nextTokenIdBefore = POSITION_MANAGER.nextTokenId();

        strategy.migrate(ILBPInitializer(address(initializer)));

        assertGt(POSITION_MANAGER.nextTokenId(), nextTokenIdBefore);
        assertGt(IERC721Balance(address(POSITION_MANAGER)).balanceOf(lpPositionRecipient), 0);
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_initAndMigrate_mintsLpPositionForStandardPlan_gas() public {
        MigrationFuzzParams memory p = _standardMigrationParams();
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        strategy.migrate(ILBPInitializer(address(initializer)));
        vm.snapshotGasLastCall("LBP migrate: standard parameters with native currency");
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

    /// @notice A second initializer migrating for the same token cannot consume the first initializer's
    /// held `supplyForLP`. Registers A under fuzzed parameters, then registers a fully-fuzzed B for the
    /// SAME token, migrates B, and asserts A's reserves are still held in the strategy untouched.
    function test_fuzz_secondInitializerMigrateCannotTouchFirstInitializersLpSupply(
        MigrationFuzzParams memory pA,
        MigrationFuzzParams memory pB
    ) public {
        // 1. Register A with fuzzed params — strategy ends up holding supplyForLP_A of `token`.
        (MockLBPInitializer initA, MockERC20 token) = _setupForMigration(pA);

        // Need headroom in block.number for B's endBlock/migrationBlock to fit in uint64.
        // _boundMigratorParams uses [block.number, uint64.max-1] for endBlock, so block.number must be < uint64.max-1.
        vm.assume(block.number < type(uint64).max - 1);

        uint128 supplyForLP_A = strategy.initializers(ILBPInitializer(address(initA))).supplyForLP;
        assertEq(token.balanceOf(address(strategy)), supplyForLP_A);

        // 2. Build B's params via the same bounding helpers. block.number is now mp_A.migrationBlock,
        //    so B's endBlock and migrationBlock will naturally end up > A's migrationBlock.
        LiquidityAllocationBracket[] memory bp_B = _boundBrackets(pB.bpParams);
        (MigratorParameters memory mp_B, uint128 totalSupply_B, uint64 endBlock_B, uint128 auctionSupply_B) =
            _boundMigratorParams(pB);
        pB.currencyRaised = _boundCurrencyRaised(pB.currencyRaised, bp_B);
        pB.initialPriceX96 = _boundInitialPriceX96(pB.initialPriceX96);
        pB.tokensSold = uint128(bound(pB.tokensSold, 1, auctionSupply_B));

        LBPInitializationParams memory lbpParams_B = LBPInitializationParams({
            initialPriceX96: pB.initialPriceX96, tokensSold: pB.tokensSold, currencyRaised: pB.currencyRaised
        });

        // 3. Fund the test contract with B's totalSupply of `token` and approve the strategy.
        deal(address(token), address(this), totalSupply_B);
        token.approve(address(strategy), totalSupply_B);

        // 4. Register B. Use a non-default salt so the mock factory deploys a fresh CCA distinct from A's.
        // _encodeConfigData populates mp_B.lpAllocationSchedule with the bp_B brackets before encoding.
        bytes memory configData_B =
            _encodeConfigData(mp_B, bp_B, _encodeMockInitializerParams(endBlock_B, address(0), lbpParams_B));
        strategy.initializeDistribution(address(token), totalSupply_B, configData_B, bytes32(uint256(1)));
        MockLBPInitializer initB = factory.deployedInitializer();

        // 5. Strategy now holds both initializers' reserves.
        assertEq(token.balanceOf(address(strategy)), uint256(supplyForLP_A) + uint256(mp_B.supplyForLP));

        // 6. Fund B's CCA with the currencyRaised it claims, roll past B's migrationBlock, and migrate B.
        vm.deal(address(initB), pB.currencyRaised);
        vm.roll(mp_B.migrationBlock);
        strategy.migrate(ILBPInitializer(address(initB)));

        // 7. A's supplyForLP is still held in the strategy — untouched by B's migrate.
        assertEq(token.balanceOf(address(strategy)), supplyForLP_A);
        assertEq(strategy.initializers(ILBPInitializer(address(initA))).supplyForLP, supplyForLP_A);
    }

    function test_fuzz_allRaisedCurrencyIsSentToFundsRecipientOrPool(MigrationFuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);
        LBPInitializationParams memory lbpParams = initializer.lbpInitializationParams();

        uint256 recipientBalBefore = leftoverRecipient.balance;
        uint256 poolManagerBalBefore = address(POOL_MANAGER).balance;

        strategy.migrate(ILBPInitializer(address(initializer)));

        uint256 currencyToFundsRecipient = leftoverRecipient.balance - recipientBalBefore;
        uint256 currencyToPool = address(POOL_MANAGER).balance - poolManagerBalBefore;

        assertEq(currencyToFundsRecipient + currencyToPool, lbpParams.currencyRaised);
        assertEq(address(strategy).balance, 0);
    }

    /// @notice E2E test with ERC20 currency (not native ETH)
    function test_fuzz_erc20Currency_initAndMigrate(MigrationFuzzParams memory p) public {
        // Deploy an ERC20 to use as currency
        MockERC20 currencyToken = new MockERC20("Currency", "CUR", type(uint128).max, address(this));

        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        // Initialize distribution with ERC20 currency
        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, bp, address(currencyToken), lbpParams);

        // Fund the initializer with ERC20 currency (not native ETH); strategy holds supplyForLP custody.
        deal(address(currencyToken), address(initializer), p.currencyRaised);
        vm.roll(mp.migrationBlock);

        Erc20MigrationBalances memory balancesBefore = Erc20MigrationBalances({
            currencyFundsRecipient: currencyToken.balanceOf(leftoverRecipient),
            currencyPool: currencyToken.balanceOf(address(POOL_MANAGER)),
            tokenFundsRecipient: token.balanceOf(leftoverRecipient),
            tokenPool: token.balanceOf(address(POOL_MANAGER))
        });

        strategy.migrate(ILBPInitializer(address(initializer)));

        _assertErc20MigrationBalances(currencyToken, token, balancesBefore, p.currencyRaised, mp.supplyForLP);
        // Strategy ends empty
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);
        // Unsold auction tokens stay in the CCA.
        assertEq(token.balanceOf(address(initializer)), auctionSupply);
    }

    function _assertErc20MigrationBalances(
        MockERC20 currencyToken,
        MockERC20 token,
        Erc20MigrationBalances memory beforeBalances,
        uint256 currencyRaised,
        uint256 supplyForLP
    ) private view {
        uint256 currencyToFundsRecipient =
            currencyToken.balanceOf(leftoverRecipient) - beforeBalances.currencyFundsRecipient;
        uint256 currencyToPool = currencyToken.balanceOf(address(POOL_MANAGER)) - beforeBalances.currencyPool;
        uint256 tokensToFundsRecipient = token.balanceOf(leftoverRecipient) - beforeBalances.tokenFundsRecipient;
        uint256 tokensToPool = token.balanceOf(address(POOL_MANAGER)) - beforeBalances.tokenPool;

        assertEq(currencyToFundsRecipient + currencyToPool, currencyRaised);
        // Only supplyForLP is distributed by the strategy; unsold auction tokens stay in the CCA.
        assertEq(tokensToFundsRecipient + tokensToPool, supplyForLP);
    }

    /// @notice Helper to build a sorted pool key for a native-currency token pair
    function _nativePoolKey(address token, uint24 fee, int24 tickSpacing, address hook)
        internal
        pure
        returns (PoolKey memory)
    {
        Currency c0 = Currency.wrap(address(0));
        Currency c1 = Currency.wrap(token);
        if (uint160(address(0)) > uint160(token)) {
            (c0, c1) = (c1, c0);
        }
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)});
    }

    /// @notice When the hookless pool doesn't exist yet, migration should initialize that pool directly
    function test_fuzz_noHook_createsRawPool(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, bp, address(0), lbpParams);
        vm.deal(address(initializer), p.currencyRaised);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        PoolKey memory rawKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, address(0));
        (uint160 rawSqrtPrice,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        assertEq(rawSqrtPrice, 0);

        strategy.migrate(ILBPInitializer(address(initializer)));

        (rawSqrtPrice,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        assertGt(rawSqrtPrice, 0);
    }

    /// @notice When the hookless pool already exists, migration initializes the strategy-hooked pool instead
    function test_fuzz_noHook_usesStrategyHookIfRawPoolExists(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        LBPInitializationParams memory lbpParams = LBPInitializationParams({
            initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
        });
        (MockLBPInitializer initializer, MockERC20 token) =
            _initializeWith(mp, totalSupply, endBlock, bp, address(0), lbpParams);
        vm.deal(address(initializer), p.currencyRaised);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        PoolKey memory rawKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, address(0));
        PoolKey memory strategyKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, address(strategy));

        (uint160 rawSqrtPrice,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        (uint160 strategySqrtPrice,,,) = POOL_MANAGER.getSlot0(strategyKey.toId());
        assertEq(rawSqrtPrice, 0);
        assertEq(strategySqrtPrice, 0);

        POOL_MANAGER.initialize(rawKey, TickMath.MIN_SQRT_PRICE + 1);
        (rawSqrtPrice,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        assertGt(rawSqrtPrice, 0);

        strategy.migrate(ILBPInitializer(address(initializer)));

        (uint160 rawSqrtPriceAfter,,,) = POOL_MANAGER.getSlot0(rawKey.toId());
        (strategySqrtPrice,,,) = POOL_MANAGER.getSlot0(strategyKey.toId());
        assertEq(rawSqrtPriceAfter, rawSqrtPrice);
        assertGt(strategySqrtPrice, 0);
        assertEq(address(strategyKey.hooks), address(strategy));
    }

    function _standardMigrationParams() internal view returns (MigrationFuzzParams memory p) {
        // Fixed values keep LBP gas benchmarks deterministic and representative of the standard launch path.
        p.endBlock = uint64(block.number);
        p.migrationBlock = uint64(block.number + 1);
        p.poolLPFee = 3000;
        p.poolTickSpacing = 60;
        p.supplyForLP = 100 ether;
        p.auctionSupply = 10 ether;
        p.bpParams.count = 1;
        p.bpParams.rate0 = 5e6;
        p.currencyRaised = 100 ether;
        p.initialPriceX96 = uint160(1 << 96);
        p.tokensSold = 1 ether;
        p.offsetLower = -600;
        p.offsetUpper = 600;
        p.fullRangeWeight = 5e6;
    }
}
