// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

/// @notice Integration and specific-value tests for initializeDistribution
/// Branch-level revert + fuzz tests are in btt/lbpV3/definitions/initializeDistribution.sol
contract LBPStrategy_InitializeDistribution_Test is LBPStrategyTestBase {
    function test_storesMigrationParameters(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    ) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) =
            _boundMigratorParams(_endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP);

        (MockLBPInitializer init1,) = _initializeWith(mp, totalSupply, endBlock);

        (ILBPStrategy.MigratorParameters memory storedParams) = strategy.initializers(ILBPInitializer(address(init1)));

        assertEq(storedParams.migrationBlock, mp.migrationBlock);
        assertEq(storedParams.poolLPFee, mp.poolLPFee);
        assertEq(storedParams.poolTickSpacing, mp.poolTickSpacing);
        assertEq(storedParams.supplyForLP, mp.supplyForLP);
    }

    function test_emitsInitializerCreated(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    ) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) =
            _boundMigratorParams(_endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        ILBPStrategy.Breakpoint[] memory bp = _defaultBreakpoints();
        bytes memory initializerParams = abi.encode(mp.supplyForLP, endBlock);

        vm.expectEmit(false, false, false, false);
        emit ILBPStrategy.InitializerCreated(ILBPInitializer(address(0)), mp, bp);
        strategy.initializeDistribution(
            address(token), totalSupply, _encodeConfigData(mp, bp, initializerParams), bytes32(0)
        );
    }

    function test_revertsIfInitializerAlreadyCreated(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    ) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) =
            _boundMigratorParams(_endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP);

        // First initialization succeeds
        (MockLBPInitializer init1,) = _initializeWith(mp, totalSupply, endBlock);

        // Force the factory to return the same initializer address
        factory.setOverrideInitializer(init1);

        // Second initialization with the same initializer should revert
        MockERC20 token2 = new MockERC20("Test Token 2", "TT2", totalSupply, address(this));
        bytes memory initializerParams = abi.encode(mp.supplyForLP, endBlock);
        bytes memory configData = _encodeConfigData(mp, _defaultBreakpoints(), initializerParams);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InitializerAlreadyCreated.selector, init1));
        strategy.initializeDistribution(address(token2), totalSupply, configData, bytes32(0));
    }
}
