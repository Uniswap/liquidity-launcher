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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

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

    /// @notice Fuzz params for all LBPStrategy tests.
    /// Tests that only need migrator params can ignore currencyRaised/initialPriceX96/tokensSold.
    struct FuzzParams {
        uint64 endBlock;
        uint64 migrationBlock;
        uint24 poolLPFee;
        int24 poolTickSpacing;
        uint128 supplyForLP;
        uint128 auctionSupply;
        uint24 currencySplitForLP;
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
            POSITION_MANAGER,
            POOL_MANAGER,
            IDistributionStrategy(address(factory)),
            1, // minSplitForLp
            address(feeController),
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
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, mp.currencySplitForLP);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (initializer, token) = _initializeWith(mp, totalSupply, endBlock);
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

    /// @notice Deploys an initializer with the given (already-bounded) MigratorParameters.
    /// Use when you need valid migrator params but want to control currencyRaised/price/tokensSold yourself
    /// (e.g., setting currencyRaised = 0 to test a revert, or wiring up an ERC20 currency).
    function _initializeWith(ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock)
        internal
        returns (MockLBPInitializer initializer, MockERC20 token)
    {
        token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        // Encode custodyTokens and endBlock into initializerParams — the mock factory reads these from configData
        bytes memory initializerParams = abi.encode(mp.supplyForLP, endBlock);
        bytes memory configData = _encodeConfigData(mp, initializerParams);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
        initializer = factory.deployedInitializer();
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
        p.currencySplitForLP = uint24(bound(p.currencySplitForLP, 1, 1e7));
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
            currencySplitForLP: p.currencySplitForLP,
            lpHook: address(0),
            positionDefinitions: _boundPositionDefinitions(p.offsetLower, p.offsetUpper, p.fullRangeWeight)
        });
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

    /// @notice Encodes MigratorParameters + initializerParams into configData for initializeDistribution
    function _encodeConfigData(ILBPStrategy.MigratorParameters memory mp, bytes memory initializerParams)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(mp, initializerParams);
    }

    /// @notice Bounds currencyRaised so that currencyAmountForLp fits in uint128 for pool creation.
    /// Min: ensures currencyRaised * split / 1e7 > 0.
    /// Currency raised above uint128 is tested separately in test_currencyAmountCappedAtUint128Max.
    function _boundCurrencyRaised(uint256 _currencyRaised, uint24 _currencySplitForLP) internal pure returns (uint256) {
        return bound(_currencyRaised, 1e7 / _currencySplitForLP + 1, type(uint128).max);
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
