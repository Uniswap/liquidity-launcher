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

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"));

        owner = address(this);

        factory = new MockInitializerFactory(address(0));

        strategy = new LBPStrategy(
            POSITION_MANAGER,
            POOL_MANAGER,
            IDistributionStrategy(address(factory)),
            1, // minSplitForLp
            makeAddr("protocolFeeController"),
            owner
        );

        factory.setStrategyAddress(address(strategy));
    }

    /// @notice Encodes MigratorParameters + initializerParams into configData for initializeDistribution
    function _encodeConfigData(ILBPStrategy.MigratorParameters memory mp, bytes memory initializerParams)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(mp, initializerParams);
    }

    /// @notice Bounds raw fuzz inputs into valid MigratorParameters and a matching totalSupply
    function _boundMigratorParams(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    )
        internal
        view
        returns (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply)
    {
        _poolLPFee = uint24(bound(_poolLPFee, 0, LPFeeLibrary.MAX_LP_FEE));
        _poolTickSpacing = int24(bound(_poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        _currencySplitForLP = uint24(bound(_currencySplitForLP, 1, 1e7));
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
            currencySplitForLP: _currencySplitForLP,
            lpHook: address(0)
        });
    }

    /// @notice Initializes distribution with custom MigratorParameters and totalSupply
    /// @return initializer The deployed MockLBPInitializer
    /// @return token The token created for this distribution
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

    /// @notice Sets up a fully funded initializer ready for migration with fuzzed parameters
    function _setupForMigration(
        ILBPStrategy.MigratorParameters memory mp,
        uint128 totalSupply,
        uint64 endBlock,
        uint128 currencyRaised,
        uint160 initialPriceX96,
        uint128 tokensSold
    ) internal returns (MockLBPInitializer initializer, MockERC20 token) {
        (initializer, token) = _initializeWith(mp, totalSupply, endBlock);
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

    /// @notice Bounds currencyRaised so that currencyRaised * split / 1e7 > 0.
    /// Without this, the currency amount for LP can round to zero and revert with NoCurrencyRaised.
    function _boundCurrencyRaised(uint128 _currencyRaised, uint24 _currencySplitForLP) internal pure returns (uint128) {
        return uint128(bound(_currencyRaised, 1e7 / _currencySplitForLP + 1, type(uint128).max));
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
