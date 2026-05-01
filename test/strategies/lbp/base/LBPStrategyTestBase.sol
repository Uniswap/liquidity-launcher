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
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

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

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"));

        owner = address(this);

        factory = new MockInitializerFactory(address(0));

        strategy = new LBPStrategy(
            POSITION_MANAGER,
            POOL_MANAGER,
            IDistributionStrategy(address(factory)),
            1, // minBracketRate
            makeAddr("protocolFeeController"),
            owner
        );

        factory.setStrategyAddress(address(strategy));
    }

    /// @notice Raw fuzz inputs for breakpoint generation — pass this as a fuzz parameter
    struct BreakpointFuzzParams {
        uint8 count;
        uint24 rate0;
        uint24 rate1;
        uint24 rate2;
        uint128 threshold0;
        uint128 threshold1;
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

    /// @notice Bounds raw fuzz inputs into valid MigratorParameters and a matching totalSupply
    function _boundMigratorParams(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    )
        internal
        view
        returns (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply)
    {
        _poolLPFee = uint24(bound(_poolLPFee, 0, LPFeeLibrary.MAX_LP_FEE));
        _poolTickSpacing = int24(bound(_poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        // CCA's MAX_TOTAL_SUPPLY is 1 << 100, which bounds auctionSupply
        auctionSupply = uint128(bound(_supplyForLP, 1, uint128(1 << 100)));
        // supplyForLP is held as CCA custody — unbounded uint128, but totalSupply must fit in uint128 (Distribution.amount)
        _supplyForLP = uint128(bound(_supplyForLP, 1, type(uint128).max - auctionSupply));
        totalSupply = _supplyForLP + auctionSupply;
        // endBlock must be < migrationBlock (validated by _validateInitializer)
        _endBlock = uint64(bound(_endBlock, uint64(block.number), type(uint64).max - 1));
        _migrationBlock = uint64(bound(_migrationBlock, _endBlock + 1, type(uint64).max));
        endBlock = _endBlock;

        mp = ILBPStrategy.MigratorParameters({
            migrationBlock: _migrationBlock,
            poolLPFee: _poolLPFee,
            poolTickSpacing: _poolTickSpacing,
            supplyForLP: _supplyForLP,
            fundsRecipient: fundsRecipient,
            lpPositionRecipient: lpPositionRecipient,
            lpHook: address(0)
        });
    }

    /// @notice Initializes distribution with custom MigratorParameters, totalSupply, and breakpoints
    /// @return initializer The deployed MockLBPInitializer
    /// @return token The token created for this distribution
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

    /// @notice Sets up a fully funded initializer ready for migration with fuzzed parameters
    function _setupForMigration(
        ILBPStrategy.MigratorParameters memory mp,
        uint128 totalSupply,
        uint64 endBlock,
        uint256 currencyRaised,
        uint256 initialPriceX96,
        uint256 tokensSold,
        ILBPStrategy.Breakpoint[] memory breakpoints
    ) internal returns (MockLBPInitializer initializer, MockERC20 token) {
        (initializer, token) = _initializeWith(mp, totalSupply, endBlock, breakpoints);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: initialPriceX96, tokensSold: tokensSold, currencyRaised: currencyRaised
            })
        );
        if (currencyRaised > 0) {
            vm.deal(address(initializer), currencyRaised);
        }
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);
        // Mock modifyLiquidities until PositionPlanner is implemented — _createPositionPlan returns empty bytes
        // which the real PositionManager would revert on. Pool initialization still hits real PoolManager.
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");
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
    /// Very small prices get inverted to values exceeding uint160.max, causing PriceTooHigh reverts.
    /// Lower bound of Q96/1e9 allows prices down to one-billionth of 1:1.
    function _boundInitialPriceX96(uint160 _initialPriceX96) internal pure returns (uint160) {
        return uint160(bound(_initialPriceX96, FixedPoint96.Q96 / 1e9, type(uint160).max));
    }
}
