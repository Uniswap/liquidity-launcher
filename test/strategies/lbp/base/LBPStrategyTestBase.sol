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

    uint128 constant DEFAULT_TOTAL_SUPPLY = 1_000e18;
    uint128 constant DEFAULT_SUPPLY_FOR_LP = 200e18;
    uint128 constant DEFAULT_CUSTODY_TOKENS = 50e18;
    uint24 constant DEFAULT_RATE = 5e6; // 50% flat rate
    uint24 constant DEFAULT_POOL_FEE = 500;
    int24 constant DEFAULT_TICK_SPACING = 10;
    uint64 constant MIGRATION_BLOCK_OFFSET = 200;
    uint128 constant DEFAULT_TOKENS_SOLD = 100e18;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"));

        owner = address(this);

        factory = new MockInitializerFactory(address(0));

        strategy = new LBPStrategy(
            POSITION_MANAGER,
            POOL_MANAGER,
            IDistributionStrategy(address(factory)),
            1,
            makeAddr("protocolFeeController"),
            owner
        );

        factory.setStrategyAddress(address(strategy));
    }

    function _defaultMigratorParams() internal view returns (ILBPStrategy.MigratorParameters memory) {
        return ILBPStrategy.MigratorParameters({
            migrationBlock: uint64(block.number) + MIGRATION_BLOCK_OFFSET,
            poolLPFee: DEFAULT_POOL_FEE,
            poolTickSpacing: DEFAULT_TICK_SPACING,
            supplyForLP: DEFAULT_SUPPLY_FOR_LP,
            fundsRecipient: fundsRecipient,
            custodyTokens: DEFAULT_CUSTODY_TOKENS,
            lpPositionRecipient: lpPositionRecipient,
            lpHook: address(0)
        });
    }

    function _defaultBreakpoints() internal pure returns (ILBPStrategy.Breakpoint[] memory) {
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](1);
        bp[0] = ILBPStrategy.Breakpoint({threshold: 0, rate: DEFAULT_RATE}); // flat rate
        return bp;
    }

    /// @notice Encodes MigratorParameters + breakpoints + initializerParams into configData
    function _encodeConfigData(
        ILBPStrategy.MigratorParameters memory mp,
        ILBPStrategy.Breakpoint[] memory breakpoints,
        bytes memory initializerParams
    ) internal pure returns (bytes memory) {
        return abi.encode(mp, breakpoints, initializerParams);
    }

    /// @notice Default configData with empty initializer params
    function _defaultConfigData() internal view returns (bytes memory) {
        return _encodeConfigData(_defaultMigratorParams(), _defaultBreakpoints(), hex"");
    }

    /// @notice Initializes distribution with default parameters and returns the deployed initializer
    function _initializeWithDefaults()
        internal
        returns (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp)
    {
        mp = _defaultMigratorParams();
        // Set custody tokens on the factory so the deployed initializer reports the expected value
        factory.setCustodyTokens(mp.supplyForLP + mp.custodyTokens);
        bytes memory configData = _encodeConfigData(mp, _defaultBreakpoints(), hex"");
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, configData, bytes32(0));
        initializer = factory.deployedInitializer();
    }

    /// @notice Sets up a fully funded initializer ready for migration
    function _setupForMigration(uint128 currencyRaised, uint160 initialPriceX96)
        internal
        returns (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp)
    {
        (initializer, mp) = _initializeWithDefaults();
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: initialPriceX96,
                tokensSold: DEFAULT_TOKENS_SOLD,
                currencyRaised: currencyRaised
            })
        );
        if (currencyRaised > 0) {
            vm.deal(address(initializer), currencyRaised);
        }
        token.transfer(address(initializer), DEFAULT_TOTAL_SUPPLY);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");
    }

    /// @notice Bounds currencyRaised so that currencyRaised * split / 1e7 > 0.
    /// Without this, the currency amount for LP can round to zero and revert with NoCurrencyRaised.
    function _boundCurrencyRaised(uint128 _currencyRaised, uint24 _currencySplitForLP) internal pure returns (uint128) {
        return uint128(bound(_currencyRaised, 1e7 / _currencySplitForLP + 1, type(uint128).max));
    }

    /// @notice Bounds initialPriceX96 to avoid overflow in TokenPricing.convertToPriceX192.
    /// Very small prices get inverted to values exceeding uint160.max, causing PriceTooHigh reverts.
    /// Lower bound of Q96/1e9 allows prices down to one-billionth of 1:1.
    function _boundInitialPriceX96(uint160 _initialPriceX96) internal pure returns (uint160) {
        return uint160(bound(_initialPriceX96, FixedPoint96.Q96 / 1e9, type(uint160).max));
    }

    /// @notice Helper to call migrate
    function _migrateWithDefaults(MockLBPInitializer initializer) internal {
        strategy.migrate(ILBPInitializer(address(initializer)));
    }
}
