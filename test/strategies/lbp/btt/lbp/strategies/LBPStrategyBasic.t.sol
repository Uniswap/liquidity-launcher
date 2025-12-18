// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttTests} from "../definitions/BttTests.sol";
import {BttBase, FuzzConstructorParameters} from "../BttBase.sol";

/// @title LBPStrategyBasicTest
/// @notice Contract for testing the LBPStrategyBasic contract
contract LBPStrategyBasicTest is BttTests {
    /// @inheritdoc BttBase
    function _contractName() internal pure override returns (string memory) {
        return "LBPStrategyBasic";
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
            _parameters.poolManager
        );
    }
}
