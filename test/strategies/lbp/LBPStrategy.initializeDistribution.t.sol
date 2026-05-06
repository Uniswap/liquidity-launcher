// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockInitializerFactory} from "test/mocks/MockInitializerFactory.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract LBPStrategy_InitializeDistribution_Test is LBPStrategyTestBase {
    function test_storesMigrationParameters(FuzzParams memory p) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        // deployedInitializer() is a test helper on MockInitializerFactory that returns the last deployed MockLBPInitializer
        (MockLBPInitializer init1,) = _initializeWith(mp, totalSupply, endBlock);

        (
            uint64 migrationBlock,
            uint24 poolLPFee,
            int24 poolTickSpacing,
            uint128 supplyForLP,
            address storedFundsRecipient,
            address storedLpPositionRecipient,
            uint24 currencySplitForLP,
            address lpHook
        ) = strategy.initializers(ILBPInitializer(address(init1)));

        assertEq(migrationBlock, mp.migrationBlock);
        assertEq(poolLPFee, mp.poolLPFee);
        assertEq(poolTickSpacing, mp.poolTickSpacing);
        assertEq(supplyForLP, mp.supplyForLP);
        assertEq(storedFundsRecipient, mp.fundsRecipient);
        assertEq(storedLpPositionRecipient, mp.lpPositionRecipient);
        assertEq(currencySplitForLP, mp.currencySplitForLP);
        assertEq(lpHook, mp.lpHook);
    }

    function test_revertsIfInitializerAlreadyCreated(FuzzParams memory p) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        // First initialization succeeds
        (MockLBPInitializer init1,) = _initializeWith(mp, totalSupply, endBlock);

        // Force the factory to return the same initializer address
        factory.setOverrideInitializer(init1);

        // Second initialization with the same initializer should revert
        MockERC20 token2 = new MockERC20("Test Token 2", "TT2", totalSupply, address(this));
        bytes memory initializerParams = abi.encode(mp.supplyForLP, endBlock);
        bytes memory configData = _encodeConfigData(mp, initializerParams);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InitializerAlreadyCreated.selector, init1));
        strategy.initializeDistribution(address(token2), totalSupply, configData, bytes32(0));
    }
}
