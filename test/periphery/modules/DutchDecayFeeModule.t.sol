// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {DutchDecayFeeModule, DutchDecayConfig} from "../../../src/periphery/modules/DutchDecayFeeModule.sol";
import {LaunchConfig} from "../../../src/interfaces/ILaunchHook.sol";
import {MockLaunchConfigStore} from "test/mocks/MockLaunchConfigStore.sol";

/// @title DutchDecayFeeModuleTest
/// @notice BTT tests for DutchDecayFeeModule
///
/// getFee
/// ├── when the block number is at or before swapStartBlock
/// │   └── it quotes startFee
/// ├── when the elapsed blocks are below decayBlocks
/// │   ├── it quotes a fee between endFee and startFee
/// │   └── it quotes monotonically decaying fees as blocks elapse
/// ├── when the elapsed blocks are at or beyond decayBlocks
/// │   └── it quotes endFee
/// ├── when decayBlocks is zero
/// │   └── it quotes endFee for any elapsed block
/// ├── when taxBothDirections is false
/// │   └── it quotes the decaying fee on the buy direction and endFee on the sell direction
/// ├── when taxBothDirections is true
/// │   └── it quotes the decaying fee on both directions
/// └── when tokenIsCurrency0 flips
///     └── it maps the buy fee to the direction that consumes token-side liquidity
contract DutchDecayFeeModuleTest is Test {
    uint48 constant SWAP_START_BLOCK = 100;

    DutchDecayFeeModule module;
    MockLaunchConfigStore store;
    PoolKey key;

    function setUp() public {
        module = new DutchDecayFeeModule();
        store = new MockLaunchConfigStore();
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 0,
            tickSpacing: 10,
            hooks: IHooks(address(store))
        });
    }

    function _setConfig(DutchDecayConfig memory config, bool tokenIsCurrency0) internal {
        store.setLaunchConfig(
            key.toId(),
            LaunchConfig({
                swapStartBlock: SWAP_START_BLOCK,
                windowEndBlock: type(uint48).max,
                baseFee: 0,
                tokenIsCurrency0: tokenIsCurrency0,
                module: address(module),
                moduleConfig: abi.encode(config)
            })
        );
    }

    /// @notice The fee quoted for the token-buy direction given the config's currency ordering
    function _buyFee(bool tokenIsCurrency0) internal view returns (uint24) {
        (uint24 zeroForOneFee, uint24 oneForZeroFee) = module.getFee(key);
        return tokenIsCurrency0 ? oneForZeroFee : zeroForOneFee;
    }

    /// @notice The fee quoted for the token-sell direction given the config's currency ordering
    function _sellFee(bool tokenIsCurrency0) internal view returns (uint24) {
        (uint24 zeroForOneFee, uint24 oneForZeroFee) = module.getFee(key);
        return tokenIsCurrency0 ? zeroForOneFee : oneForZeroFee;
    }

    function _config(uint24 startFee, uint24 endFee, uint48 decayBlocks, bool both)
        internal
        pure
        returns (DutchDecayConfig memory)
    {
        return DutchDecayConfig({startFee: startFee, endFee: endFee, decayBlocks: decayBlocks, taxBothDirections: both});
    }

    function test_fuzz_getFee_quotesStartFeeAtOrBeforeSwapStartBlock(
        uint24 startFee,
        uint24 endFee,
        uint48 decayBlocks,
        uint48 currentBlock,
        bool tokenIsCurrency0
    ) public {
        currentBlock = uint48(bound(currentBlock, 1, SWAP_START_BLOCK));
        _setConfig(_config(startFee, endFee, decayBlocks, true), tokenIsCurrency0);

        vm.roll(currentBlock);
        assertEq(_buyFee(tokenIsCurrency0), startFee);
    }

    function test_fuzz_getFee_quotesBoundedFeeInsideDecay(
        uint24 startFee,
        uint24 endFee,
        uint48 decayBlocks,
        uint48 elapsed,
        bool tokenIsCurrency0
    ) public {
        decayBlocks = uint48(bound(decayBlocks, 2, 1_000_000));
        elapsed = uint48(bound(elapsed, 1, decayBlocks - 1));
        _setConfig(_config(startFee, endFee, decayBlocks, true), tokenIsCurrency0);

        vm.roll(SWAP_START_BLOCK + elapsed);
        uint24 fee = _buyFee(tokenIsCurrency0);
        uint24 min = startFee < endFee ? startFee : endFee;
        uint24 max = startFee < endFee ? endFee : startFee;
        assertGe(fee, min);
        assertLe(fee, max);
    }

    function test_fuzz_getFee_decaysMonotonically(
        uint24 startFee,
        uint24 endFee,
        uint48 decayBlocks,
        uint48 elapsedA,
        uint48 elapsedB
    ) public {
        startFee = uint24(bound(startFee, 0, type(uint24).max));
        endFee = uint24(bound(endFee, 0, startFee));
        decayBlocks = uint48(bound(decayBlocks, 2, 1_000_000));
        elapsedA = uint48(bound(elapsedA, 0, decayBlocks));
        elapsedB = uint48(bound(elapsedB, elapsedA, decayBlocks));
        _setConfig(_config(startFee, endFee, decayBlocks, true), true);

        vm.roll(SWAP_START_BLOCK + elapsedA);
        uint24 feeA = _buyFee(true);
        vm.roll(SWAP_START_BLOCK + elapsedB);
        uint24 feeB = _buyFee(true);

        assertGe(feeA, feeB);
    }

    function test_fuzz_getFee_quotesEndFeeAfterDecay(
        uint24 startFee,
        uint24 endFee,
        uint48 decayBlocks,
        uint48 extraBlocks,
        bool tokenIsCurrency0
    ) public {
        decayBlocks = uint48(bound(decayBlocks, 0, 1_000_000));
        extraBlocks = uint48(bound(extraBlocks, 0, 1_000_000));
        _setConfig(_config(startFee, endFee, decayBlocks, true), tokenIsCurrency0);

        vm.roll(uint256(SWAP_START_BLOCK) + decayBlocks + extraBlocks + 1);
        assertEq(_buyFee(tokenIsCurrency0), endFee);
    }

    function test_fuzz_getFee_quotesEndFeeWhenDecayBlocksIsZero(uint24 startFee, uint24 endFee, uint48 elapsed) public {
        elapsed = uint48(bound(elapsed, 1, 1_000_000));
        _setConfig(_config(startFee, endFee, 0, true), true);

        vm.roll(SWAP_START_BLOCK + elapsed);
        assertEq(_buyFee(true), endFee);
    }

    function test_fuzz_getFee_quotesEndFeeOnSellsWhenNotTaxingBothDirections(
        uint24 startFee,
        uint24 endFee,
        uint48 decayBlocks,
        bool tokenIsCurrency0
    ) public {
        decayBlocks = uint48(bound(decayBlocks, 2, 1_000_000));
        _setConfig(_config(startFee, endFee, decayBlocks, false), tokenIsCurrency0);

        // At the swap start block the buy direction quotes startFee while sells already quote endFee.
        vm.roll(SWAP_START_BLOCK);
        assertEq(_buyFee(tokenIsCurrency0), startFee);
        assertEq(_sellFee(tokenIsCurrency0), endFee);
    }

    function test_fuzz_getFee_quotesSameFeeBothDirectionsWhenTaxingBoth(
        uint24 startFee,
        uint24 endFee,
        uint48 decayBlocks,
        uint48 elapsed,
        bool tokenIsCurrency0
    ) public {
        decayBlocks = uint48(bound(decayBlocks, 1, 1_000_000));
        elapsed = uint48(bound(elapsed, 0, decayBlocks));
        _setConfig(_config(startFee, endFee, decayBlocks, true), tokenIsCurrency0);

        vm.roll(SWAP_START_BLOCK + elapsed);
        (uint24 zeroForOneFee, uint24 oneForZeroFee) = module.getFee(key);
        assertEq(zeroForOneFee, oneForZeroFee);
    }

    function test_getFee_mapsBuyFeeToTokenSideDirection() public {
        // token = currency0: buys are oneForZero
        _setConfig(_config(900_000, 3000, 100, false), true);
        vm.roll(SWAP_START_BLOCK);
        (uint24 zeroForOneFee, uint24 oneForZeroFee) = module.getFee(key);
        assertEq(oneForZeroFee, 900_000);
        assertEq(zeroForOneFee, 3000);

        // token = currency1: buys are zeroForOne
        _setConfig(_config(900_000, 3000, 100, false), false);
        (zeroForOneFee, oneForZeroFee) = module.getFee(key);
        assertEq(zeroForOneFee, 900_000);
        assertEq(oneForZeroFee, 3000);
    }
}
