// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FrontrunningProtectionHook} from "src/periphery/hooks/FrontrunningProtectionHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

contract FrontrunningProtectionHookNoValidation is FrontrunningProtectionHook {
    constructor(IPoolManager _pm, address _strategy) FrontrunningProtectionHook(_pm, _strategy) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice End-to-end fuzz tests exercising the full initializeDistribution → migrate flow
contract LBPStrategy_E2E_Test is LBPStrategyTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant CLEAR_ALL_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;

    function _deployFrontrunningHook() internal returns (address hookAddr) {
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG;
        hookAddr = address(uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | flags));

        FrontrunningProtectionHookNoValidation impl =
            new FrontrunningProtectionHookNoValidation(POOL_MANAGER, address(strategy));
        vm.etch(hookAddr, address(impl).code);
    }

    /// @notice Full init → migrate flow with native ETH currency:
    /// - it stores the MigratorParameters
    /// - it migrates successfully after migrationBlock
    /// - it leaves no funds in the strategy
    /// - it sends leftover currency and tokens to fundsRecipient
    function test_fuzz_initAndMigrate_happyPath(FuzzParams memory p) public {
        (MockLBPInitializer initializer, MockERC20 token) = _setupForMigration(p);

        // it stores the MigratorParameters
        (uint64 storedMigrationBlock,,,,,,,) = strategy.initializers(ILBPInitializer(address(initializer)));
        assertGt(storedMigrationBlock, 0);

        uint256 recipientBalBefore = fundsRecipient.balance;
        uint256 recipientTokenBalBefore = token.balanceOf(fundsRecipient);

        // it migrates successfully after migrationBlock
        strategy.migrate(ILBPInitializer(address(initializer)));

        // it leaves no funds in the strategy
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(address(strategy).balance, 0);

        // it sends leftover currency and tokens to fundsRecipient
        assertTrue(
            fundsRecipient.balance > recipientBalBefore || token.balanceOf(fundsRecipient) > recipientTokenBalBefore
        );
    }

    /// @notice Two independent distributions store separate migration parameters
    function test_fuzz_twoDistributionsStoreSeparateParams(FuzzParams memory p1, FuzzParams memory p2) public {
        (ILBPStrategy.MigratorParameters memory mp1, uint128 totalSupply1, uint64 endBlock1,) = _boundMigratorParams(p1);
        (ILBPStrategy.MigratorParameters memory mp2, uint128 totalSupply2, uint64 endBlock2,) = _boundMigratorParams(p2);

        (MockLBPInitializer init1,) = _initializeWith(mp1, totalSupply1, endBlock1);
        (MockLBPInitializer init2,) = _initializeWith(mp2, totalSupply2, endBlock2);

        (uint64 stored1,,,,,,,) = strategy.initializers(ILBPInitializer(address(init1)));
        (uint64 stored2,,,,,,,) = strategy.initializers(ILBPInitializer(address(init2)));
        assertEq(stored1, mp1.migrationBlock);
        assertEq(stored2, mp2.migrationBlock);
    }

    function test_fuzz_currencySplitAppliedCorrectly(FuzzParams memory p) public {
        (MockLBPInitializer initializer,) = _setupForMigration(p);

        uint256 recipientBalBefore = fundsRecipient.balance;
        strategy.migrate(ILBPInitializer(address(initializer)));

        // Since _createPositionPlan is a stub, all currency gets swept — no LP is created.
        // TODO: Once _createPositionPlan is implemented, assert at most currencySplitForLP share goes to LP.
        uint256 received = fundsRecipient.balance - recipientBalBefore;
        assertGe(received, p.currencyRaised);
    }

    /// @notice E2E test with ERC20 currency (not native ETH)
    function test_fuzz_erc20Currency_initAndMigrate(FuzzParams memory p) public {
        // Deploy an ERC20 to use as currency
        MockERC20 currencyToken = new MockERC20("Currency", "CUR", type(uint128).max, address(this));
        factory.setCurrencyOverride(address(currencyToken));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, mp.currencySplitForLP);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        // Initialize distribution
        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
            })
        );

        // Fund the initializer with ERC20 currency (not native ETH)
        currencyToken.transfer(address(initializer), p.currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        uint256 recipientCurrencyBefore = currencyToken.balanceOf(fundsRecipient);
        uint256 recipientTokenBefore = token.balanceOf(fundsRecipient);

        strategy.migrate(ILBPInitializer(address(initializer)));

        // Strategy should be empty
        assertEq(currencyToken.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);

        // fundsRecipient should have received something
        assertTrue(
            currencyToken.balanceOf(fundsRecipient) > recipientCurrencyBefore
                || token.balanceOf(fundsRecipient) > recipientTokenBefore
        );
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

    /// @notice When lpHook only has beforeInitialize and the hookless pool doesn't exist yet,
    /// migration should create a hookless pool (hooks = address(0))
    function test_fuzz_beforeInitializeHook_createsHooklessPool(FuzzParams memory p) public {
        address hookAddr = _deployFrontrunningHook();

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        mp.lpHook = hookAddr;
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, mp.currencySplitForLP);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
            })
        );
        vm.deal(address(initializer), p.currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        PoolKey memory hooklessKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, address(0));
        (uint160 hooklessSqrtPrice,,,) = POOL_MANAGER.getSlot0(hooklessKey.toId());
        assertEq(hooklessSqrtPrice, 0); // hookless pool should not be initialized yet

        PoolKey memory hookedKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, hookAddr);
        (uint160 hookedSqrtPrice,,,) = POOL_MANAGER.getSlot0(hookedKey.toId());
        assertEq(hookedSqrtPrice, 0); // hooked pool should not be initialized yet

        strategy.migrate(ILBPInitializer(address(initializer)));

        // The hookless pool should be initialized (hook = address(0))
        (hooklessSqrtPrice,,,) = POOL_MANAGER.getSlot0(hooklessKey.toId());
        assertGt(hooklessSqrtPrice, 0); // hookless pool should be initialized

        (hookedSqrtPrice,,,) = POOL_MANAGER.getSlot0(hookedKey.toId());
        assertEq(hookedSqrtPrice, 0); // hooked pool should still not be initialized
    }

    /// @notice When lpHook only has beforeInitialize but the hookless pool already exists,
    /// migration should fall back to the hooked pool
    function test_fuzz_beforeInitializeHook_fallsBackToHookedPool(FuzzParams memory p) public {
        address hookAddr = _deployFrontrunningHook();

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock, uint128 auctionSupply) =
            _boundMigratorParams(p);
        mp.lpHook = hookAddr;
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, mp.currencySplitForLP);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        (MockLBPInitializer initializer, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock);
        initializer.setLbpInitializationParams(
            LBPInitializationParams({
                initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
            })
        );
        vm.deal(address(initializer), p.currencyRaised);
        token.transfer(address(initializer), totalSupply);
        vm.roll(mp.migrationBlock);
        vm.mockCall(address(POSITION_MANAGER), abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "");

        // Pre-initialize the hookless pool so strategy must fall back to the hooked pool
        PoolKey memory hooklessKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, address(0));
        PoolKey memory hookedKey = _nativePoolKey(address(token), mp.poolLPFee, mp.poolTickSpacing, hookAddr);

        (uint160 hooklessSqrtPrice,,,) = POOL_MANAGER.getSlot0(hooklessKey.toId());
        assertEq(hooklessSqrtPrice, 0); // hookless pool should not be initialized yet

        (uint160 hookedSqrtPrice,,,) = POOL_MANAGER.getSlot0(hookedKey.toId());
        assertEq(hookedSqrtPrice, 0); // hooked pool should not be initialized yet

        POOL_MANAGER.initialize(hooklessKey, TickMath.MIN_SQRT_PRICE + 1);
        (hooklessSqrtPrice,,,) = POOL_MANAGER.getSlot0(hooklessKey.toId());
        assertGt(hooklessSqrtPrice, 0); // hookless pool should be initialized

        (hookedSqrtPrice,,,) = POOL_MANAGER.getSlot0(hookedKey.toId());
        assertEq(hookedSqrtPrice, 0); // hooked pool should still not be initialized

        strategy.migrate(ILBPInitializer(address(initializer)));

        (hookedSqrtPrice,,,) = POOL_MANAGER.getSlot0(hookedKey.toId());
        assertGt(hookedSqrtPrice, 0); // hooked pool should be initialized
    }
}
