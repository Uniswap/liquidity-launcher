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

abstract contract LBPStrategyTestBase is Test {
    LBPStrategy strategy;
    MockInitializerFactory factory;
    MockERC20 token;

    address poolManager = makeAddr("poolManager");
    address positionManager = makeAddr("positionManager");
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
        owner = address(this);

        token = new MockERC20("Test Token", "TT", DEFAULT_TOTAL_SUPPLY, address(this));

        // Deploy factory first with a placeholder strategy address.
        // Then deploy strategy with the real factory.
        // Then update the factory's strategyAddress to match.
        factory = new MockInitializerFactory(address(0));

        strategy = new LBPStrategy(
            IPositionManager(positionManager),
            IPoolManager(poolManager),
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

    function _setupForMigration(uint256 currencyRaised, uint256 initialPriceX96)
        internal
        returns (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp)
    {
        return _setupForMigration(currencyRaised, initialPriceX96, DEFAULT_TOKENS_SOLD);
    }

    function _setupForMigration(uint256 currencyRaised, uint256 initialPriceX96, uint256 tokensSold)
        internal
        returns (MockLBPInitializer initializer, ILBPStrategy.MigratorParameters memory mp)
    {
        (initializer, mp) = _initializeWithDefaults();
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: initialPriceX96, tokensSold: tokensSold, currencyRaised: currencyRaised
            })
        );
        if (currencyRaised > 0 && currencyRaised <= type(uint128).max) {
            vm.deal(address(initializer), currencyRaised);
        }
        token.transfer(address(initializer), DEFAULT_SUPPLY_FOR_LP + DEFAULT_CUSTODY_TOKENS);
        vm.roll(mp.migrationBlock);
        vm.mockCall(poolManager, abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(int24(0)));
        vm.mockCall(positionManager, abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");
    }

    /// @notice Helper to call migrate
    function _migrateWithDefaults(MockLBPInitializer initializer) internal {
        strategy.migrate(ILBPInitializer(address(initializer)));
    }
}
