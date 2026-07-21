// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";
import {ILPFeesPositionRecipient} from "../../src/interfaces/ILPFeesPositionRecipient.sol";
import {CompoundingPositionRecipient} from "../../src/periphery/CompoundingPositionRecipient.sol";
import {MockLPFeesExecutor} from "./MockLPFeesExecutor.sol";
import {MockCompoundingLPFeesExecutor} from "./MockCompoundingLPFeesExecutor.sol";
import {TimelockedPositionRecipientTest} from "./TimelockedPositionRecipient.t.sol";

contract CompoundingPositionRecipientTest is TimelockedPositionRecipientTest {
    address internal constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    CompoundingPositionRecipient internal positionRecipient;
    MockCompoundingLPFeesExecutor internal executor;

    function setUp() public override {
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        executor = new MockCompoundingLPFeesExecutor(IPositionManager(POSITION_MANAGER), IWETH9(WETH9));
    }

    function _getPositionRecipient(uint64 _timelockBlockNumber)
        internal
        override
        returns (ITimelockedPositionRecipient)
    {
        return new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, 1);
    }

    function test_Constructor_WhenMinimumLiquidityIncreaseIsZero_Reverts(uint64 timelockBlockNumber) public {
        vm.expectRevert(CompoundingPositionRecipient.MinLiquidityIncreaseIsZero.selector);
        new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, timelockBlockNumber, 0);
    }

    function test_Constructor_WhenParametersAreValid_SetsConfiguration(
        uint64 timelockBlockNumber,
        uint128 minLiquidityIncrease
    ) public {
        minLiquidityIncrease = uint128(bound(minLiquidityIncrease, 1, type(uint128).max));
        positionRecipient = new CompoundingPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, timelockBlockNumber, minLiquidityIncrease
        );

        assertEq(positionRecipient.timelockBlockNumber(), timelockBlockNumber);
        assertEq(positionRecipient.MIN_LIQUIDITY_INCREASE(), minLiquidityIncrease);
        assertEq(positionRecipient.operator(), operator);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
    }

    function test_CollectFees_WhenPositionDoesNotExist_Reverts() public {
        positionRecipient = new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);

        vm.expectRevert(abi.encodeWithSelector(ILPFeesPositionRecipient.InvalidPosition.selector, type(uint256).max));
        executor.execute(positionRecipient, type(uint256).max, 0, 0);
    }

    function test_CollectFees_WhenPositionIsNotOwned_Reverts() public {
        positionRecipient = new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(positionRecipient)));
        executor.execute(positionRecipient, FORK_TOKEN_ID, 0, 0);
    }

    function test_CollectFees_WhenLiquidityIncreaseIsInsufficient_Reverts() public {
        positionRecipient =
            new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, type(uint128).max);
        MockLPFeesExecutor noopExecutor = new MockLPFeesExecutor();
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));
        uint128 liquidityBefore = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundingPositionRecipient.NotEnoughLiquidityAdded.selector,
                uint256(liquidityBefore) + type(uint128).max,
                liquidityBefore
            )
        );
        noopExecutor.execute(positionRecipient, FORK_TOKEN_ID, 0, 0);
    }

    function test_CollectFees_WhenExecutorDepositsFees_IncreasesLiquidity() public {
        positionRecipient = new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));
        uint128 liquidityBefore = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);
        uint256 recipientCurrency0Before = Currency.wrap(NATIVE).balanceOf(address(positionRecipient));
        uint256 recipientCurrency1Before = Currency.wrap(USDC).balanceOf(address(positionRecipient));

        executor.execute(positionRecipient, FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0);

        uint128 liquidityAfter = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);
        assertGt(liquidityAfter, liquidityBefore);
        assertEq(executor.lastTokenId(), FORK_TOKEN_ID);
        assertEq(executor.lastCurrency0Received(), FORK_CURRENCY0_FEES_AMOUNT);
        assertGt(executor.lastCurrency1Received(), 0);
        assertEq(Currency.wrap(NATIVE).balanceOf(address(positionRecipient)), recipientCurrency0Before);
        assertEq(Currency.wrap(USDC).balanceOf(address(positionRecipient)), recipientCurrency1Before);
    }
}
