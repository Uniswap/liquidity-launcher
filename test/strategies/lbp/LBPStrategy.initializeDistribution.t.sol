// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "../../../src/interfaces/ILBPStrategy.sol";
import {IDistributorFactory} from "../../../src/interfaces/IDistributorFactory.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "../../../src/libraries/MigratorParams.sol";
import {ILBPInitializer, LBPInitializationParams} from "../../../src/interfaces/ILBPInitializer.sol";
import {IInitializerHook} from "../../../src/interfaces/IInitializerHook.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {GatedSwapHook} from "../../../src/periphery/hooks/GatedSwapHook.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {MigratorParams} from "../../../src/libraries/MigratorParams.sol";

contract GatedSwapHookNoValidation is GatedSwapHook {
    constructor(IPoolManager _pm, address _strategy, address _gatekeeper) GatedSwapHook(_pm, _strategy, _gatekeeper) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice Integration and specific-value tests for initializeDistribution
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/initializeDistribution.sol
contract LBPStrategy_InitializeDistribution_Test is LBPStrategyTestBase {
    function test_storesMigrationParameters(MigrationFuzzParams memory p) public {
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        (MockLBPInitializer init1,) = _initializeWith(mp, totalSupply, endBlock, _boundBrackets(p.bpParams));

        (MigratorParameters memory storedParams) = strategy.initializers(ILBPInitializer(address(init1)));

        assertEq(storedParams.migrationBlock, mp.migrationBlock);
        assertEq(storedParams.poolParameters.fee, mp.poolParameters.fee);
        assertEq(storedParams.poolParameters.tickSpacing, mp.poolParameters.tickSpacing);
        assertEq(storedParams.reservedTokenAmountForLP, mp.reservedTokenAmountForLP);
        assertEq(storedParams.recipient, mp.recipient);
        assertEq(storedParams.poolParameters.hook, mp.poolParameters.hook);
        assertEq(storedParams.positionDefinitions, mp.positionDefinitions);
        assertEq(storedParams.lpAllocationSchedule, abi.encode(_boundBrackets(p.bpParams)));
    }

    function test_emitsInitializerCreated(MigrationFuzzParams memory p) public {
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        mp.token = address(token);
        bytes memory initializerParams = _encodeMockInitializerParams(
            endBlock, address(0), LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0})
        );
        token.approve(address(strategy), totalSupply);

        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.InitializerCreated(ILBPInitializer(address(0)), mp);
        strategy.initializeDistribution(
            address(token), totalSupply, _encodeConfigData(mp, bp, initializerParams), bytes32(0)
        );
    }

    function test_forwardsSaltDerivedFromCallerSaltAndMigratorParams(MigrationFuzzParams memory p, bytes32 salt)
        public
    {
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        mp.token = address(token);
        bytes memory initializerParams = _encodeMockInitializerParams(
            endBlock, address(0), LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0})
        );
        bytes memory configData = _encodeConfigData(mp, bp, initializerParams);
        (MigratorParameters memory decodedMigrationParams,) = abi.decode(configData, (MigratorParameters, bytes));
        bytes32 expectedInitializerSalt = keccak256(abi.encode(salt, decodedMigrationParams));
        uint256 auctionSupply = totalSupply - mp.reservedTokenAmountForLP;
        token.approve(address(strategy), totalSupply);

        vm.expectCall(
            address(factory),
            abi.encodeCall(
                IDistributorFactory.create, (address(token), auctionSupply, initializerParams, expectedInitializerSalt)
            )
        );

        strategy.initializeDistribution(address(token), totalSupply, configData, salt);
    }

    function test_revertsIfInitializerAlreadyCreated(MigrationFuzzParams memory p) public {
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);

        // First initialization succeeds
        (MockLBPInitializer init1,) = _initializeWith(mp, totalSupply, endBlock, bp);

        // Force the factory to return the same initializer address
        factory.setOverrideInitializer(init1);

        // Second initialization with the same initializer should revert
        MockERC20 token2 = new MockERC20("Test Token 2", "TT2", totalSupply, address(this));
        bytes memory initializerParams = _encodeMockInitializerParams(
            endBlock, address(0), LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0})
        );
        bytes memory configData = _encodeConfigData(mp, bp, initializerParams);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InitializerAlreadyCreated.selector, init1));
        strategy.initializeDistribution(address(token2), totalSupply, configData, bytes32(0));
    }

    function test_initializeDistribution_revertsIfHookDoesNotSupportInitializerHook(MigrationFuzzParams memory p)
        public
    {
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        mp.poolParameters.hook = makeAddr("hookWithoutInitializerHookSupport");

        // validateHook now runs after the initializer is deployed and token consistency is checked, so the
        // config must be otherwise valid (matching token/currency, well-formed mock params) to reach it.
        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        mp.token = address(token);
        bytes memory initializerParams = _encodeMockInitializerParams(
            endBlock, address(0), LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0})
        );
        bytes memory configData = _encodeConfigData(mp, bp, initializerParams);
        token.approve(address(strategy), totalSupply);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, mp.poolParameters.hook));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    function test_initializeDistribution_revertsIfDynamicFeeHasNoHook(MigrationFuzzParams memory p) public {
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        mp.poolParameters.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        mp.poolParameters.hook = address(0);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        mp.token = address(token);
        bytes memory initializerParams = _encodeMockInitializerParams(
            endBlock, address(0), LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0})
        );
        bytes memory configData = _encodeConfigData(mp, bp, initializerParams);
        token.approve(address(strategy), totalSupply);

        vm.expectRevert(MigratorParams.InvalidDynamicFeeHook.selector);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    function test_initializeDistribution_acceptsHookThatSupportsInitializerHook(MigrationFuzzParams memory p) public {
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);

        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG));
        GatedSwapHookNoValidation impl = new GatedSwapHookNoValidation(
            IPoolManager(address(POOL_MANAGER)), address(strategy), makeAddr("gatekeeper")
        );
        vm.etch(hookAddr, address(impl).code);
        mp.poolParameters.hook = hookAddr;

        assertTrue(IInitializerHook(hookAddr).supportsInterface(type(IInitializerHook).interfaceId));

        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, bp);
        (MigratorParameters memory storedParams) = strategy.initializers(ILBPInitializer(address(initializer)));
        assertEq(storedParams.poolParameters.hook, hookAddr);
    }

    /// @notice Registration reserves the resulting poolId; a second launch resolving to the same
    /// (currency, token, fee, tickSpacing, hook) is rejected with PoolIdOccupied.
    function test_initializeDistribution_revertsIfPoolIdOccupied(MigrationFuzzParams memory p) public {
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);

        // First registration reserves the pool key (hook == address(0) from _boundMigratorParams).
        (MockLBPInitializer first, MockERC20 token) = _initializeWith(mp, totalSupply, endBlock, bp);
        assertEq(_registeredFor(ILBPInitializer(address(first))), address(first));

        // A second launch with the SAME token + pool params resolves to the same poolId.
        deal(address(token), address(this), totalSupply);
        token.approve(address(strategy), totalSupply);
        bytes memory configData =
            _encodeConfigData(mp, bp, _encodeMockInitializerParams(endBlock, address(0), _zeroLbpParams()));

        PoolId poolId = _poolIdFor(ILBPInitializer(address(first)));
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.PoolIdOccupied.selector, poolId, address(first)));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(uint256(1)));
    }

    /// @notice The strategy address is reserved as the hookless fallback hook, so it cannot be set as
    /// an explicit migration hook.
    function test_initializeDistribution_revertsIfHookIsStrategy(MigrationFuzzParams memory p) public {
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        mp.poolParameters.hook = address(strategy);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        mp.token = address(token);
        bytes memory configData =
            _encodeConfigData(mp, bp, _encodeMockInitializerParams(endBlock, address(0), _zeroLbpParams()));
        token.approve(address(strategy), totalSupply);

        vm.expectRevert(ILBPStrategy.HookIsStrategy.selector);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    /// @notice For a hookless launch, registration fails fast if the raw pool is already initialized
    /// (validateHook's getSlot0 check), since that launch could never migrate into it.
    function test_initializeDistribution_revertsIfHooklessPoolAlreadyInitialized(MigrationFuzzParams memory p) public {
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        mp.token = address(token);

        // Front-run: initialize the raw hookless pool before registration.
        PoolKey memory rawKey =
            _poolKey(address(0), address(token), mp.poolParameters.fee, mp.poolParameters.tickSpacing, address(0));
        POOL_MANAGER.initialize(rawKey, uint160(1 << 96));

        bytes memory configData =
            _encodeConfigData(mp, bp, _encodeMockInitializerParams(endBlock, address(0), _zeroLbpParams()));
        token.approve(address(strategy), totalSupply);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, address(0)));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    function _zeroLbpParams() internal pure returns (LBPInitializationParams memory) {
        return LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0});
    }
}
