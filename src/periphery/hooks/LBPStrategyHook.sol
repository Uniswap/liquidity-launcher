// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title SelfInitializerMixin
/// @notice Minimal mixin for hooks which only allow themselves to initialize pools
// contract LBPStrategyHook is IHooks {

//     address public immutable lbpStrategy;
//     address public immutable initializer;

//     error OnlyLBPStrategyCanCall();
//     error InvalidInitializer();
//     error NotAuthorized();

//     constructor(address lbpStrategyAddress, address initializerAddress) {
//         if(lbpStrategyAddress != msg.sender) revert OnlyLBPStrategyCanCall();
//         lbpStrategy = lbpStrategyAddress;
//         initializer = initializerAddress;

//         Hooks.Permissions memory permissions;
//         permissions.beforeInitialize = true;
//         Hooks.validateHookPermissions(IHooks(address(this)), permissions);
//     }

//     /// @notice Reverts any beforeInitialize callback
//     /// @dev V4 skips beforeInitialize when sender == hook, so any callback is not a self-call.
//     function beforeInitialize(address sender, PoolKey calldata, uint160) external pure returns (bytes4) {
//         if(sender != lbpStrategy) revert OnlyLBPStrategyCanCall();

//         assembly ("memory-safe") {
//             if iszero(tload(initializer)) {
//                 mstore(0xc4, 0xadc06ae7) // InvalidInitializer()
//                 revert(0x1c, 0x04)
//             }
//         }

//         return IHooks.beforeInitialize.selector;
//     }

//     function authorize(address authorized) external {
//         if(msg.sender != lbpStrategy) revert OnlyLBPStrategyCanCall();
//         if(authorized != initializer) revert NotAuthorized();

//         assembly ("memory-safe") {
//             tstore(initializer, 1)
//         }
//     }
// }
