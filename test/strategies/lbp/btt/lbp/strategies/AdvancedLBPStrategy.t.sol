// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttTests} from "../definitions/BttTests.sol";
import {BttBase, FuzzConstructorParameters} from "../BttBase.sol";

/// @title AdvancedLBPStrategyTest
/// @notice Contract for testing the AdvancedLBPStrategy contract
contract AdvancedLBPStrategyTest is BttTests {
    /// @inheritdoc BttBase
    function _contractName() internal pure override returns (string memory) {
        return "AdvancedLBPStrategy";
    }

    /// @inheritdoc BttBase
    function _encodeConstructorArgs(FuzzConstructorParameters memory _parameters)
        internal
        pure
        override
        returns (bytes memory)
    {
        return abi.encode(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager,
            // Default to not creating one sided positions for backwards compatibility
            false,
            false
        );
    }
}
