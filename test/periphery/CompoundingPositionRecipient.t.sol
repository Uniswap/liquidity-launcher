// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";
import {IClaimablePositionRecipient} from "../../src/interfaces/IClaimablePositionRecipient.sol";
import {CompoundingPositionRecipient} from "../../src/periphery/CompoundingPositionRecipient.sol";
import {FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {IFeeSplitter, FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {MockClaimExecutor} from "./MockClaimExecutor.sol";
import {MockCompoundingClaimExecutor} from "./MockCompoundingClaimExecutor.sol";
import {TimelockedPositionRecipientTest} from "./TimelockedPositionRecipient.t.sol";

contract CompoundingPositionRecipientTest is TimelockedPositionRecipientTest {
    address internal constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    CompoundingPositionRecipient internal positionRecipient;
    MockCompoundingClaimExecutor internal executor;

    function setUp() public override {
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        executor = new MockCompoundingClaimExecutor(IPositionManager(POSITION_MANAGER), IWETH9(WETH9));
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

    function test_Claim_WhenPositionDoesNotExist_Reverts() public {
        positionRecipient = new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);

        vm.expectRevert(abi.encodeWithSelector(IClaimablePositionRecipient.InvalidPosition.selector, type(uint256).max));
        executor.execute(positionRecipient, type(uint256).max, 0, 0);
    }

    function test_OnAmountsReceived_WhenPositionIsNotOwned_RecordsAmounts() public {
        positionRecipient = new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);
        vm.deal(address(positionRecipient), FORK_CURRENCY0_FEES_AMOUNT);

        positionRecipient.onAmountsReceived(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0);

        (uint256 currency0Amount, uint256 currency1Amount) = positionRecipient.amounts(FORK_TOKEN_ID);
        assertEq(currency0Amount, FORK_CURRENCY0_FEES_AMOUNT);
        assertEq(currency1Amount, 0);
    }

    function test_Claim_WhenLiquidityIncreaseIsInsufficient_Reverts() public {
        positionRecipient =
            new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, type(uint128).max);
        MockClaimExecutor noopExecutor = new MockClaimExecutor();
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

    function test_Claim_WhenExecutorDepositsFees_IncreasesLiquidity() public {
        positionRecipient = new CompoundingPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);
        FeeSplitter splitter = _callbackSplitter(address(positionRecipient));
        uint256 recipientCurrency0Before = Currency.wrap(NATIVE).balanceOf(address(positionRecipient));
        uint256 recipientCurrency1Before = Currency.wrap(USDC).balanceOf(address(positionRecipient));
        _yoinkPosition(FORK_TOKEN_ID, address(splitter));
        splitter.collectFees(_single(FORK_TOKEN_ID));
        executor.setFeeSplitter(IFeeSplitter(address(splitter)), 1);
        uint128 liquidityBefore = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);

        executor.execute(positionRecipient, FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0);

        uint128 liquidityAfter = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);
        assertGt(liquidityAfter, liquidityBefore);
        assertEq(executor.lastTokenId(), FORK_TOKEN_ID);
        assertEq(executor.lastCurrency0Received(), FORK_CURRENCY0_FEES_AMOUNT);
        assertGt(executor.lastCurrency1Received(), 0);
        assertEq(Currency.wrap(NATIVE).balanceOf(address(positionRecipient)), recipientCurrency0Before);
        assertEq(Currency.wrap(USDC).balanceOf(address(positionRecipient)), recipientCurrency1Before);
    }

    function _callbackSplitter(address recipient) internal returns (FeeSplitter splitter) {
        FeeSplit[] memory splits = new FeeSplit[](1);
        splits[0] = FeeSplit({recipient: recipient, nativeBps: 10_000, tokenBps: 10_000, useCallback: true});
        splitter = new FeeSplitter(IPositionManager(POSITION_MANAGER), address(this), address(this), splits);
    }

    function _single(uint256 tokenId) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
    }
}
