// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/strategies/lbp/FullRangeLBPStrategy.sol";
import {BttTests} from "../definitions/BttTests.sol";
import {BttBase} from "../BttBase.sol";
import {ILBPStrategyTestExtension} from "./ILBPStrategyTestExtension.sol";

contract FullRangeLBPStrategyTestExtension is FullRangeLBPStrategy, ILBPStrategyTestExtension {
    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _initializerParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager
    ) FullRangeLBPStrategy(_token, _totalSupply, _migratorParams, _initializerParams, _positionManager, _poolManager) {}

    function prepareMigrationData() external view returns (MigrationData memory) {
        return _prepareMigrationData();
    }

    function createPositionPlan(MigrationData memory data) external view returns (bytes memory) {
        return _createPositionPlan(data);
    }

    function getTokenTransferAmount(MigrationData memory data) external pure returns (uint128) {
        return _getTokenTransferAmount(data);
    }

    function getCurrencyTransferAmount(MigrationData memory data) external pure returns (uint128) {
        return _getCurrencyTransferAmount(data);
    }

    function getPoolToken() external view returns (address) {
        return _getPoolToken();
    }

    function transferAssetsAndExecutePlan(
        uint128 tokenTransferAmount,
        uint128 currencyTransferAmount,
        bytes memory plan
    ) external {
        return _transferAssetsAndExecutePlan(tokenTransferAmount, currencyTransferAmount, plan);
    }
}

/// @title FullRangeLBPStrategyTest
/// @notice Contract for testing the FullRangeLBPStrategy contract
contract FullRangeLBPStrategyTest is BttTests {
    /// @inheritdoc BttBase
    function _contractName() internal pure override returns (string memory) {
        return "FullRangeLBPStrategyTestExtension";
    }
}
