// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttTests} from "../definitions/BttTests.sol";
import {BttBase, FuzzConstructorParameters} from "../BttBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title GovernedLBPStrategyTest
/// @notice Contract for testing the GovernedLBPStrategy contract
contract GovernedLBPStrategyTest is BttTests {
    // TODO: dummy governance address
    address governance = makeAddr("governance");

    /// @inheritdoc BttBase
    function _contractName() internal pure override returns (string memory) {
        return "GovernedLBPStrategy";
    }

    /// @inheritdoc BttBase
    function _getHookAddress() internal pure override returns (address) {
        return address(
            uint160(
                uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_FLAG
            )
        );
    }

    /// @inheritdoc BttBase
    function _encodeConstructorArgs(FuzzConstructorParameters memory _parameters)
        internal
        view
        override
        returns (bytes memory)
    {
        return abi.encode(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.initializerParameters,
            _parameters.positionManager,
            _parameters.poolManager,
            governance
        );
    }
}
