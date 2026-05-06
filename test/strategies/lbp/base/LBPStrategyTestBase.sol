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
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

/// @notice Base test contract for LBPStrategy tests.
/// Forks mainnet to use real v4 PoolManager and PositionManager.
/// Uses mock CCA (MockInitializerFactory + MockLBPInitializer) for auction simulation.
abstract contract LBPStrategyTestBase is Test {
    // Mainnet v4 deployments
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    LBPStrategy strategy;
    MockInitializerFactory factory;

    address owner;
    address fundsRecipient = makeAddr("fundsRecipient");
    address lpPositionRecipient = makeAddr("lpPositionRecipient");

    /// @notice Raw fuzz inputs for breakpoint generation — pass this as a fuzz parameter
    struct BreakpointFuzzParams {
        uint8 count;
        uint24 rate0;
        uint24 rate1;
        uint24 rate2;
        uint128 threshold0;
        uint128 threshold1;
    }

    /// @notice Fuzz params for all LBPStrategy tests.
    /// Tests that only need migrator params can ignore currencyRaised/initialPriceX96/tokensSold.
    struct FuzzParams {
        uint64 endBlock;
        uint64 migrationBlock;
        uint24 poolLPFee;
        int24 poolTickSpacing;
        uint128 supplyForLP;
        uint128 auctionSupply;
        BreakpointFuzzParams bpParams;
        uint256 currencyRaised;
        uint160 initialPriceX96;
        uint128 tokensSold;
    }

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"));

        owner = address(this);

        factory = new MockInitializerFactory(address(0));

        strategy = new LBPStrategy(
            POSITION_MANAGER,
            POOL_MANAGER,
            IDistributionStrategy(address(factory)),
            makeAddr("protocolFeeController"),
            owner
        );

        factory.setStrategyAddress(address(strategy));
    }

    /// @notice One-liner for a happy-path migration setup: bounds all fuzz params, deploys and funds
    /// the initializer, and rolls to the migration block. Use _boundMigratorParams + _initializeWith
    /// directly when you need to customize the migration inputs (e.g., zero currency, ERC20 currency).
    function _setupForMigration(FuzzParams memory p)
        internal
        returns (MockLBPInitializer initializer, MockERC20 token)
    {
        (ILBPStrategy.Breakpoint[] memory bp,) = _boundBreakpoints(p.bpParams);
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (initializer, token) = _initializeWith(mp, totalSupply, endBlock, bp);
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
        // Mock modifyLiquidities until PositionPlanner is implemented — _createPositionPlan returns empty bytes
        // which the real PositionManager would revert on. Pool initialization still hits real PoolManager.
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");
    }

    /// @notice Deploys an initializer with the given (already-bounded) MigratorParameters and breakpoints.
    /// Use when you need valid migrator params but want to control currencyRaised/price/tokensSold yourself
    /// (e.g., setting currencyRaised = 0 to test a revert, or wiring up an ERC20 currency).
    function _initializeWith(
        ILBPStrategy.MigratorParameters memory mp,
        uint128 totalSupply,
        uint64 endBlock,
        ILBPStrategy.Breakpoint[] memory breakpoints
    ) internal returns (MockLBPInitializer initializer, MockERC20 token) {
        token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory initializerParams = abi.encode(mp.supplyForLP, endBlock);
        bytes memory configData = _encodeConfigData(mp, breakpoints, initializerParams);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
        initializer = factory.deployedInitializer();
    }

    /// @notice Convenience overload with a default single breakpoint at 100% rate
    function _initializeWith(ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock)
        internal
        returns (MockLBPInitializer initializer, MockERC20 token)
    {
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](1);
        bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: strategy.MAX_BRACKET_RATE()});
        return _initializeWith(mp, totalSupply, endBlock, bp);
    }

    /// @notice Bounds the migrator-related fields of FuzzParams into valid MigratorParameters.
    /// Does NOT touch currencyRaised/initialPriceX96/tokensSold — use _setupForMigration for that.
    function _boundMigratorParams(FuzzParams memory p)
        internal
        view
        returns (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply)
    {
        p.poolLPFee = uint24(bound(p.poolLPFee, 0, LPFeeLibrary.MAX_LP_FEE));
        p.poolTickSpacing = int24(bound(p.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        // CCA's MAX_TOTAL_SUPPLY is 1 << 100, which bounds auctionSupply
        auctionSupply = uint128(bound(p.auctionSupply, 1, uint128(1 << 100)));
        // supplyForLP is held as CCA custody — unbounded uint128, but totalSupply must fit in uint128 (Distribution.amount)
        p.supplyForLP = uint128(bound(p.supplyForLP, 1, type(uint128).max - auctionSupply));
        totalSupply = p.supplyForLP + auctionSupply;
        // endBlock must be < migrationBlock (validated by _validateInitializer)
        p.endBlock = uint64(bound(p.endBlock, uint64(block.number), type(uint64).max - 1));
        p.migrationBlock = uint64(bound(p.migrationBlock, p.endBlock + 1, type(uint64).max));
        endBlock = p.endBlock;

        mp = ILBPStrategy.MigratorParameters({
            migrationBlock: p.migrationBlock,
            poolLPFee: p.poolLPFee,
            poolTickSpacing: p.poolTickSpacing,
            supplyForLP: p.supplyForLP,
            fundsRecipient: fundsRecipient,
            lpPositionRecipient: lpPositionRecipient,
            lpHook: address(0)
        });
    }

    /// @notice Bounds raw fuzz inputs into a valid breakpoint array (1-3 breakpoints)
    /// @return bp Valid breakpoints with ascending lowerThresholds and rates in [1, strategy.MAX_BRACKET_RATE()]
    /// @return minRate The smallest rate across all breakpoints
    function _boundBreakpoints(BreakpointFuzzParams memory p)
        internal
        view
        returns (ILBPStrategy.Breakpoint[] memory bp, uint24 minRate)
    {
        uint256 count = bound(p.count, 1, 3);
        bp = new ILBPStrategy.Breakpoint[](count);

        uint24 r0 = uint24(bound(p.rate0, 1, strategy.MAX_BRACKET_RATE()));
        minRate = r0;

        if (count == 1) {
            bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: r0});
        } else if (count == 2) {
            uint24 r1 = uint24(bound(p.rate1, 1, strategy.MAX_BRACKET_RATE()));
            uint128 t1 = uint128(bound(p.threshold0, 1, type(uint128).max));
            bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: r0});
            bp[1] = ILBPStrategy.Breakpoint({lowerThreshold: t1, rate: r1});
            minRate = r0 < r1 ? r0 : r1;
        } else {
            uint24 r1 = uint24(bound(p.rate1, 1, strategy.MAX_BRACKET_RATE()));
            uint24 r2 = uint24(bound(p.rate2, 1, strategy.MAX_BRACKET_RATE()));
            uint128 t1 = uint128(bound(p.threshold0, 1, type(uint128).max - 1));
            uint128 t2 = uint128(bound(p.threshold1, t1 + 1, type(uint128).max));
            bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: r0});
            bp[1] = ILBPStrategy.Breakpoint({lowerThreshold: t1, rate: r1});
            bp[2] = ILBPStrategy.Breakpoint({lowerThreshold: t2, rate: r2});
            minRate = r0 < r1 ? (r0 < r2 ? r0 : r2) : (r1 < r2 ? r1 : r2);
        }
    }

    /// @notice Encodes InitializerRecord + initializerParams into configData
    function _encodeConfigData(
        ILBPStrategy.MigratorParameters memory mp,
        ILBPStrategy.Breakpoint[] memory breakpoints,
        bytes memory initializerParams
    ) internal pure returns (bytes memory) {
        ILBPStrategy.InitializerRecord memory record =
            ILBPStrategy.InitializerRecord({params: mp, breakpoints: breakpoints});
        return abi.encode(record, initializerParams);
    }

    /// @notice Convenience overload with a default single breakpoint at 100% rate
    function _encodeConfigData(ILBPStrategy.MigratorParameters memory mp, bytes memory initializerParams)
        internal
        pure
        returns (bytes memory)
    {
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](1);
        bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: 1e7});
        return _encodeConfigData(mp, bp, initializerParams);
    }

    /// @notice Bounds currencyRaised so that the total LP amount across all brackets is non-zero.
    ///
    /// Mirrors the strategy's _calculateCurrencyAmountForLp bracket loop to find the minimum
    /// currencyRaised that produces a non-zero total. This avoids excluding valid configs where
    /// some brackets round to 0 but the total is still positive.
    ///
    /// Upper bound prevents overflow in the strategy's bracketAmount * rate multiplication.
    function _boundCurrencyRaised(uint256 _currencyRaised, ILBPStrategy.Breakpoint[] memory _breakpoints)
        internal
        view
        returns (uint256)
    {
        uint256 minCurrency = _minCurrencyForNonZeroLp(_breakpoints);
        return bound(_currencyRaised, minCurrency, type(uint256).max / strategy.MAX_BRACKET_RATE());
    }

    /// @notice Finds the minimum currencyRaised that produces non-zero LP via the bracket calculation.
    /// Iterates through each bracket and returns as soon as one produces >= 1 wei of LP.
    function _minCurrencyForNonZeroLp(ILBPStrategy.Breakpoint[] memory _breakpoints) internal view returns (uint256) {
        uint256 len = _breakpoints.length;

        for (uint256 i; i < len; ++i) {
            uint24 rate = _breakpoints[i].rate;
            uint256 lowerThreshold = uint256(_breakpoints[i].lowerThreshold);

            // Skip brackets with rate 0 — they can't produce LP
            if (rate == 0) continue;

            // The minimum bracketAmount for this bracket to produce >= 1 LP: strategy.MAX_BRACKET_RATE() / rate + 1
            uint256 minBracketAmount = strategy.MAX_BRACKET_RATE() / rate + 1;

            if (i == len - 1) {
                // Last bracket: receives all remaining currency above lowerThreshold
                return lowerThreshold + minBracketAmount;
            }

            uint256 nextThreshold = uint256(_breakpoints[i + 1].lowerThreshold);
            uint256 bracketSize = nextThreshold - lowerThreshold;

            // If this bracket is large enough to produce >= 1 LP, currencyRaised just needs
            // to reach far enough into this bracket
            if (bracketSize >= minBracketAmount) {
                return lowerThreshold + minBracketAmount;
            }

            // Otherwise this bracket rounds to 0 — move on to the next
        }
        revert(); // Should never reach here
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
