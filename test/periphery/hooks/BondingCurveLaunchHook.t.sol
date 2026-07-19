// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BondingCurveLaunchHook} from "../../../src/periphery/hooks/BondingCurveLaunchHook.sol";
import {
    IBondingCurveLaunchHook,
    BondingCurveHookConfig,
    BondingCurvePhase
} from "../../../src/interfaces/IBondingCurveLaunchHook.sol";

/// @title BondingCurveLaunchHookTest
/// @notice Unit tests for the hook's authorized configuration, phase gating, and permissions. The
///         swap/graduation callbacks require the live PoolManager and are covered by the e2e suite.
contract BondingCurveLaunchHookTest is Test {
    IPoolManager internal constant POOL_MANAGER = IPoolManager(address(0x1111));
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(address(0x2222));
    int24 internal constant INITIAL_TICK = 122_000;
    int24 internal constant GRADUATION_TICK = 94_200;
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    BondingCurveLaunchHook internal hook;
    PoolId internal poolId = PoolId.wrap(keccak256("pool"));

    function setUp() public {
        // Authorized is this test, so it can call configure() directly.
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(BondingCurveLaunchHook).creationCode,
            abi.encode(POOL_MANAGER, POSITION_MANAGER, address(this))
        );
        hook = new BondingCurveLaunchHook{salt: salt}(POOL_MANAGER, POSITION_MANAGER, address(this));
        assertEq(address(hook), hookAddress);
    }

    function _validConfig() internal view returns (BondingCurveHookConfig memory) {
        return BondingCurveHookConfig({
            reserveTokenAmount: 1,
            finalPositionRecipient: address(0xBEEF),
            graduationSqrtPriceX96: TickMath.getSqrtPriceAtTick(GRADUATION_TICK),
            curveTickLower: GRADUATION_TICK,
            curveTickUpper: INITIAL_TICK,
            swapStartBlock: uint48(block.number),
            module: address(0)
        });
    }

    function test_constructor_revertsOnZeroPositionManager() public {
        (address addr, bytes32 salt) = HookMiner.find(
            address(this),
            HOOK_FLAGS,
            type(BondingCurveLaunchHook).creationCode,
            abi.encode(POOL_MANAGER, IPositionManager(address(0)), address(this))
        );
        addr; // silence unused
        vm.expectRevert(IBondingCurveLaunchHook.ZeroAddress.selector);
        new BondingCurveLaunchHook{salt: salt}(POOL_MANAGER, IPositionManager(address(0)), address(this));
    }

    function test_permissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
    }

    function test_configure_onlyAuthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(IBondingCurveLaunchHook.NotAuthorized.selector, makeAddr("stranger"), address(this))
        );
        vm.prank(makeAddr("stranger"));
        hook.configure(poolId, _validConfig());
    }

    function test_configure_setsSeedingAndStoresConfig() public {
        BondingCurveHookConfig memory config = _validConfig();
        vm.expectEmit(true, false, false, true, address(hook));
        emit IBondingCurveLaunchHook.BondingCurveConfigured(poolId, config);
        hook.configure(poolId, config);

        assertEq(uint256(hook.bondingCurvePhase(poolId)), uint256(BondingCurvePhase.Seeding));
        assertEq(hook.bondingCurveConfig(poolId).reserveTokenAmount, 1);
        assertEq(hook.bondingCurveConfig(poolId).curveTickLower, GRADUATION_TICK);
        assertEq(hook.bondingCurveConfig(poolId).curveTickUpper, INITIAL_TICK);
    }

    function test_configure_revertsWhenAlreadyConfigured() public {
        hook.configure(poolId, _validConfig());
        vm.expectRevert(abi.encodeWithSelector(IBondingCurveLaunchHook.AlreadyConfigured.selector, poolId));
        hook.configure(poolId, _validConfig());
    }

    function test_configure_revertsOnZeroReserve() public {
        BondingCurveHookConfig memory config = _validConfig();
        config.reserveTokenAmount = 0;
        vm.expectRevert(IBondingCurveLaunchHook.InvalidBondingCurveConfig.selector);
        hook.configure(poolId, config);
    }

    function test_configure_revertsOnZeroRecipient() public {
        BondingCurveHookConfig memory config = _validConfig();
        config.finalPositionRecipient = address(0);
        vm.expectRevert(IBondingCurveLaunchHook.InvalidBondingCurveConfig.selector);
        hook.configure(poolId, config);
    }

    function test_configure_revertsOnDisorderedTicks() public {
        BondingCurveHookConfig memory config = _validConfig();
        (config.curveTickLower, config.curveTickUpper) = (INITIAL_TICK, GRADUATION_TICK);
        vm.expectRevert(IBondingCurveLaunchHook.InvalidBondingCurveConfig.selector);
        hook.configure(poolId, config);
    }

    function test_configure_revertsOnGraduationPriceMismatch() public {
        BondingCurveHookConfig memory config = _validConfig();
        config.graduationSqrtPriceX96 = TickMath.getSqrtPriceAtTick(GRADUATION_TICK + 200);
        vm.expectRevert(IBondingCurveLaunchHook.InvalidBondingCurveConfig.selector);
        hook.configure(poolId, config);
    }
}
