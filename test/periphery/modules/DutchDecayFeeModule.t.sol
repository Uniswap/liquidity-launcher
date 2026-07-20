// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {DutchDecayFeeModule} from "../../../src/periphery/modules/DutchDecayFeeModule.sol";
import {BondingCurveHookConfig} from "../../../src/interfaces/IBondingCurveLaunchHook.sol";

/// @notice Minimal stand-in for the launch hook: the module reads only `swapStartBlock` from it.
contract MockConfigHook {
    BondingCurveHookConfig internal _config;

    function setSwapStartBlock(uint48 swapStartBlock) external {
        _config.swapStartBlock = swapStartBlock;
    }

    function bondingCurveConfig(PoolId) external view returns (BondingCurveHookConfig memory) {
        return _config;
    }
}

/// @title DutchDecayFeeModuleTest
/// @notice Unit tests for the linear fee decay and direction handling.
contract DutchDecayFeeModuleTest is Test {
    uint24 internal constant START_FEE = 990_000;
    uint24 internal constant END_FEE = 0;
    uint48 internal constant DECAY_BLOCKS = 5;

    MockConfigHook internal hook;
    PoolKey internal key;

    function setUp() public {
        hook = new MockConfigHook();
        key.hooks = IHooks(address(hook));
        vm.roll(100);
        hook.setSwapStartBlock(uint48(block.number));
    }

    function _module(bool taxBothDirections) internal returns (DutchDecayFeeModule) {
        return new DutchDecayFeeModule(START_FEE, END_FEE, DECAY_BLOCKS, taxBothDirections);
    }

    function test_atOrBeforeSwapStart_isStartFee() public {
        DutchDecayFeeModule module = _module(true);
        (uint24 z, uint24 o) = module.getFee(key);
        assertEq(z, START_FEE);
        assertEq(o, START_FEE);
        // A block before the start also clamps to startFee.
        hook.setSwapStartBlock(uint48(block.number + 1));
        (z,) = module.getFee(key);
        assertEq(z, START_FEE);
    }

    function test_linearDecay_interpolatesPerBlock() public {
        DutchDecayFeeModule module = _module(true);
        // fee = startFee * (1 - elapsed/decayBlocks)
        vm.roll(block.number + 1);
        (uint24 z1,) = module.getFee(key);
        assertEq(z1, uint24(uint256(START_FEE) * 4 / 5)); // 792_000
        vm.roll(block.number + 1);
        (uint24 z2,) = module.getFee(key);
        assertEq(z2, uint24(uint256(START_FEE) * 3 / 5)); // 594_000
    }

    function test_afterWindow_isEndFee() public {
        DutchDecayFeeModule module = _module(true);
        vm.roll(block.number + DECAY_BLOCKS);
        (uint24 z, uint24 o) = module.getFee(key);
        assertEq(z, END_FEE);
        assertEq(o, END_FEE);
    }

    function test_taxBothDirections_taxesBuyAndSellEqually() public {
        DutchDecayFeeModule module = _module(true);
        vm.roll(block.number + 1);
        (uint24 z, uint24 o) = module.getFee(key);
        assertEq(z, o);
        assertGt(z, END_FEE);
    }

    function test_taxOneDirection_sellPaysEndFee() public {
        DutchDecayFeeModule module = _module(false);
        vm.roll(block.number + 1);
        (uint24 zeroForOneBuy, uint24 oneForZeroSell) = module.getFee(key);
        assertGt(zeroForOneBuy, END_FEE); // buy still decays
        assertEq(oneForZeroSell, END_FEE); // sell is untaxed
    }

    function test_immutablesExposed() public {
        DutchDecayFeeModule module = _module(true);
        assertEq(module.startFee(), START_FEE);
        assertEq(module.endFee(), END_FEE);
        assertEq(module.decayBlocks(), DECAY_BLOCKS);
        assertTrue(module.taxBothDirections());
    }
}
