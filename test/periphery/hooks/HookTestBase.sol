// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

abstract contract HookTestBase is Test {
    uint160 internal constant CLEAR_ALL_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;

    address poolManager = makeAddr("poolManager");
    address strategy = makeAddr("strategy");

    function _computeHookAddress(uint160 flags) internal pure returns (address) {
        return address(uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | flags));
    }

    function _defaultPoolKey(address hook) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(hook)
        });
    }
}
