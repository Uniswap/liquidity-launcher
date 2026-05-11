// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LBPStrategy} from "src/strategies/lbp/LBPStrategy.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockInitializerFactory} from "test/mocks/MockInitializerFactory.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockProtocolFeeController} from "test/mocks/MockProtocolFeeController.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";
import {MigratorParams, MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice Base test contract for LBPStrategy tests.
/// Uses local v4 PoolManager and PositionManager deployments at canonical addresses.
/// Uses mock CCA (MockInitializerFactory + MockLBPInitializer) for auction simulation.
abstract contract LBPStrategyTestBase is Test {
    // Canonical v4 deployment addresses
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    LBPStrategy strategy;
    MockInitializerFactory factory;
    MockProtocolFeeController feeController;

    address owner;
    address fundsRecipient = makeAddr("fundsRecipient");
    address lpPositionRecipient = makeAddr("lpPositionRecipient");

    /// @notice Raw fuzz inputs for LP allocation bracket generation — pass this as a fuzz parameter
    struct BracketFuzzParams {
        uint8 count;
        uint24 rate0;
        uint24 rate1;
        uint24 rate2;
        uint128 threshold0;
        uint128 threshold1;
    }

    /// @notice Fuzz params for all LBPStrategy tests.
    /// Tests that only need migrator params can ignore currencyRaised/initialPriceX96/tokensSold.
    struct MigrationFuzzParams {
        uint64 endBlock;
        uint64 migrationBlock;
        uint24 poolLPFee;
        int24 poolTickSpacing;
        uint128 supplyForLP;
        uint128 auctionSupply;
        BracketFuzzParams bpParams;
        uint256 currencyRaised;
        uint160 initialPriceX96;
        uint128 tokensSold;
        int24 offsetLower;
        int24 offsetUpper;
        uint24 fullRangeWeight;
    }

    function setUp() public virtual {
        owner = address(this);

        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(owner), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );

        factory = new MockInitializerFactory(address(0));

        feeController = new MockProtocolFeeController();

        strategy = new LBPStrategy(
            POSITION_MANAGER, POOL_MANAGER, IDistributionStrategy(address(factory)), address(feeController), owner
        );

        factory.setStrategyAddress(address(strategy));
    }

    /// @notice One-liner for a happy-path migration setup: bounds all fuzz params, deploys and funds
    /// the initializer, and rolls to the migration block. Use _boundMigratorParams + _initializeWith
    /// directly when you need to customize the migration inputs (e.g., zero currency, ERC20 currency).
    function _setupForMigration(MigrationFuzzParams memory p)
        internal
        returns (MockLBPInitializer initializer, MockERC20 token)
    {
        LiquidityAllocationBracket[] memory brackets = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, brackets);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (initializer, token) = _initializeWith(mp, totalSupply, endBlock, brackets);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
            })
        );
        if (p.currencyRaised > 0) {
            vm.deal(address(initializer), p.currencyRaised);
        }
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);
    }

    /// @notice Deploys an initializer with the given (already-bounded) MigratorParameters and bracket schedule.
    /// Use when you need valid migrator params but want to control currencyRaised/price/tokensSold yourself
    /// (e.g., wiring up an ERC20 currency).
    function _initializeWith(
        MigratorParameters memory mp,
        uint128 totalSupply,
        uint64 endBlock,
        LiquidityAllocationBracket[] memory brackets
    ) internal returns (MockLBPInitializer initializer, MockERC20 token) {
        token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory initializerParams = abi.encode(mp.supplyForLP, endBlock);
        bytes memory configData = _encodeConfigData(mp, brackets, initializerParams);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
        initializer = factory.deployedInitializer();
    }

    /// @notice Bounds the migrator-related fields of MigrationFuzzParams into valid MigratorParameters.
    /// Does NOT touch currencyRaised/initialPriceX96/tokensSold — use _setupForMigration for that.
    /// The returned MigratorParameters has an empty lpAllocationSchedule; callers populate it via _encodeConfigData.
    function _boundMigratorParams(MigrationFuzzParams memory p)
        internal
        view
        returns (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply)
    {
        p.poolLPFee = uint24(bound(p.poolLPFee, 0, LPFeeLibrary.MAX_LP_FEE));
        p.poolTickSpacing = int24(bound(p.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        // CCA's MAX_TOTAL_SUPPLY is 1 << 100, which bounds auctionSupply
        auctionSupply = uint128(bound(p.auctionSupply, 1, uint128(1 << 100)));
        // supplyForLP must fit in int128 (v4 delta limit, enforced by MigratorParams.validate)
        p.supplyForLP = uint128(bound(p.supplyForLP, 1, uint128(type(int128).max) - auctionSupply));
        totalSupply = p.supplyForLP + auctionSupply;
        // endBlock must be < migrationBlock (validated by _validateInitializer)
        p.endBlock = uint64(bound(p.endBlock, uint64(block.number), type(uint64).max - 1));
        p.migrationBlock = uint64(bound(p.migrationBlock, p.endBlock + 1, type(uint64).max));
        endBlock = p.endBlock;

        mp = MigratorParameters({
            migrationBlock: p.migrationBlock,
            poolLPFee: p.poolLPFee,
            poolTickSpacing: p.poolTickSpacing,
            supplyForLP: p.supplyForLP,
            fundsRecipient: fundsRecipient,
            lpPositionRecipient: lpPositionRecipient,
            lpHook: address(0),
            positionDefinitions: _boundPositionDefinitions(p.offsetLower, p.offsetUpper, p.fullRangeWeight),
            lpAllocationSchedule: new bytes(0)
        });
    }

    /// @notice Bounds raw fuzz inputs into a valid LP allocation bracket array (1-3 brackets)
    /// @return brackets Valid brackets with first lowerThreshold = 0, strictly ascending lowerThresholds, and rates in [1, MigratorParams.MAX_BRACKET_RATE]
    function _boundBrackets(BracketFuzzParams memory p)
        internal
        pure
        returns (LiquidityAllocationBracket[] memory brackets)
    {
        uint256 count = bound(p.count, 1, 3);
        brackets = new LiquidityAllocationBracket[](count);

        uint24 r0 = uint24(bound(p.rate0, 1, MigratorParams.MAX_BRACKET_RATE));

        if (count == 1) {
            brackets[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: r0});
        } else if (count == 2) {
            uint24 r1 = uint24(bound(p.rate1, 1, MigratorParams.MAX_BRACKET_RATE));
            uint128 t1 = uint128(bound(p.threshold0, 1, type(uint128).max));
            brackets[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: r0});
            brackets[1] = LiquidityAllocationBracket({lowerThreshold: t1, rate: r1});
        } else {
            uint24 r1 = uint24(bound(p.rate1, 1, MigratorParams.MAX_BRACKET_RATE));
            uint24 r2 = uint24(bound(p.rate2, 1, MigratorParams.MAX_BRACKET_RATE));
            uint128 t1 = uint128(bound(p.threshold0, 1, type(uint128).max - 1));
            uint128 t2 = uint128(bound(p.threshold1, t1 + 1, type(uint128).max));
            brackets[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: r0});
            brackets[1] = LiquidityAllocationBracket({lowerThreshold: t1, rate: r1});
            brackets[2] = LiquidityAllocationBracket({lowerThreshold: t2, rate: r2});
        }
    }

    /// @notice Bounds fuzzed position inputs into a valid two-position plan.
    function _boundPositionDefinitions(int24 _offsetLower, int24 _offsetUpper, uint24 _fullRangeWeight)
        internal
        pure
        returns (bytes memory)
    {
        _offsetLower = int24(bound(_offsetLower, -10000, -1));
        _offsetUpper = int24(bound(_offsetUpper, 1, 10000));
        _fullRangeWeight = uint24(bound(_fullRangeWeight, 1, 1e7 - 1));

        PositionDefinition[] memory defs = new PositionDefinition[](2);
        defs[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: _fullRangeWeight
        });
        defs[1] = PositionDefinition({
            offsetLower: _offsetLower, offsetUpper: _offsetUpper, weight: uint24(1e7) - _fullRangeWeight
        });
        return abi.encode(defs);
    }

    /// @notice Encodes MigratorParameters (with embedded abi-encoded schedule) + initializerParams into configData
    function _encodeConfigData(
        MigratorParameters memory mp,
        LiquidityAllocationBracket[] memory brackets,
        bytes memory initializerParams
    ) internal pure returns (bytes memory) {
        mp.lpAllocationSchedule = abi.encode(brackets);
        return abi.encode(mp, initializerParams);
    }

    /// @notice Bounds currencyRaised into a range that produces non-zero LP and migrates cleanly.
    /// Lower bound: minimum currencyRaised that yields >= 1 LP (some brackets may round to 0).
    /// Upper bound: int128.max — v4's PoolManager._accountDelta uses int128 for currency deltas
    /// The cap-and-sweep path for currencyRaised > int128.max is covered by test_currencyAmountCappedAtInt128Max.
    function _boundCurrencyRaised(uint256 _currencyRaised, LiquidityAllocationBracket[] memory _brackets)
        internal
        pure
        returns (uint256)
    {
        uint256 minCurrency = _minCurrencyForNonZeroLp(_brackets);
        return bound(_currencyRaised, minCurrency, uint256(uint128(type(int128).max)));
    }

    /// @notice Finds the minimum currencyRaised such that the schedule's total LP is >= 1.
    /// For each bracket, computes how much currency must flow INTO it to produce >= 1 LP, and how
    /// much currency the bracket can actually hold. Returns at the first bracket where the latter
    /// covers the former.
    function _minCurrencyForNonZeroLp(LiquidityAllocationBracket[] memory _brackets) internal pure returns (uint256) {
        uint256 len = _brackets.length;
        uint256 maxRate = MigratorParams.MAX_BRACKET_RATE;

        for (uint256 i = 0; i < len; i++) {
            uint24 rate = _brackets[i].rate;
            if (rate == 0) continue;

            uint256 lowerThreshold = _brackets[i].lowerThreshold;
            // Min currency inside this bracket so floor(amount * rate / maxRate) >= 1.
            uint256 minAmountInBracket = maxRate / rate + 1;
            // Last bracket has unbounded capacity; middle brackets are capped by the next threshold.
            uint256 capacity =
                i == len - 1 ? type(uint256).max : uint256(_brackets[i + 1].lowerThreshold) - lowerThreshold;

            if (capacity >= minAmountInBracket) {
                return lowerThreshold + minAmountInBracket;
            }
        }
        revert(); // Should never reach here
    }

    /// @notice Reference implementation of LBPStrategy._calculateCurrencyAmountForLp.
    /// @dev Mirrors the contract's bracket iteration: each non-last bracket allocates
    /// min(remaining, bracketSize) at its rate, last bracket's rate applies to all remaining.
    /// Tests use this to assert the exact LP currency budget the strategy will plan against.
    function _expectedLpCurrencyAmount(uint256 currencyAmount, LiquidityAllocationBracket[] memory _brackets)
        internal
        pure
        returns (uint256 lpAmount)
    {
        uint256 remaining = currencyAmount;
        uint256 count = _brackets.length;

        for (uint256 i = 0; i < count; i++) {
            uint24 rate = _brackets[i].rate;

            if (i == count - 1) {
                lpAmount += FullMath.mulDiv(remaining, rate, MigratorParams.MAX_BRACKET_RATE);
                break;
            }

            uint256 bracketSize = uint256(_brackets[i + 1].lowerThreshold) - uint256(_brackets[i].lowerThreshold);
            uint256 bracketAmount = remaining > bracketSize ? bracketSize : remaining;
            lpAmount += FullMath.mulDiv(bracketAmount, rate, MigratorParams.MAX_BRACKET_RATE);
            remaining -= bracketAmount;

            if (remaining == 0) break;
        }
    }

    /// @notice Bounds initialPriceX96 to avoid overflow in TokenPricing.convertToPriceX192.
    /// When currencyIsCurrency0, the price is inverted: Q192/price. This reverts with PriceTooHigh
    /// when the inverse exceeds uint160.max, i.e. when price <= Q192 / uint160.max ≈ 2^32.
    /// The +1 gives us the first price where the inverse fits in uint160.
    function _boundInitialPriceX96(uint160 _initialPriceX96) internal pure returns (uint160) {
        uint256 minPrice = (uint256(1) << 192) / type(uint160).max + 1;
        return uint160(bound(_initialPriceX96, minPrice, type(uint160).max));
    }
}
