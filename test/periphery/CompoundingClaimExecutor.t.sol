// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IClaimableRecipient} from "../../src/interfaces/IClaimableRecipient.sol";
import {IFeeSplitter, FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {CompoundingClaimRecipient} from "../../src/periphery/CompoundingClaimRecipient.sol";
import {FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {CompoundingClaimExecutor} from "../../script/contracts/periphery/CompoundingClaimExecutor.sol";
import {PositionRecipientTestBase} from "./PositionRecipientTestBase.sol";

/// @notice Covers the executor that `CollectAndCompoundFees.s.sol` deploys to drive compounding claims
contract CompoundingClaimExecutorTest is PositionRecipientTestBase {
    uint256 internal constant LIQUIDITY_BUFFER_BPS = 1;

    CompoundingClaimRecipient internal recipient;
    FeeSplitter internal splitter;
    CompoundingClaimExecutor internal executor;

    function setUp() public override {
        super.setUp();
        recipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        splitter = _callbackSplitter(address(recipient));
        executor = new CompoundingClaimExecutor(
            IFeeSplitter(address(splitter)), IClaimableRecipient(address(recipient)), LIQUIDITY_BUFFER_BPS
        );
    }

    function test_Constructor_ReadsConfigurationFromTheFeeSplitter() public view {
        assertEq(address(executor.positionManager()), POSITION_MANAGER);
        assertEq(address(executor.poolManager()), POOL_MANAGER);
        assertEq(address(executor.feeSplitter()), address(splitter));
        assertEq(address(executor.recipient()), address(recipient));
        assertEq(executor.liquidityBufferBps(), LIQUIDITY_BUFFER_BPS);
    }

    function test_Constructor_WhenBufferExceedsMaximum_Reverts() public {
        uint256 bufferBps = executor.MAX_LIQUIDITY_BUFFER_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(CompoundingClaimExecutor.LiquidityBufferTooLarge.selector, bufferBps));
        new CompoundingClaimExecutor(
            IFeeSplitter(address(splitter)), IClaimableRecipient(address(recipient)), bufferBps
        );
    }

    function test_Constructor_WhenRecipientUsesAnotherPositionManager_Reverts() public {
        CompoundingClaimRecipient foreignRecipient = new CompoundingClaimRecipient(IPositionManager(address(this)), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundingClaimExecutor.PositionManagerMismatch.selector, POSITION_MANAGER, address(this)
            )
        );
        new CompoundingClaimExecutor(
            IFeeSplitter(address(splitter)), IClaimableRecipient(address(foreignRecipient)), LIQUIDITY_BUFFER_BPS
        );
    }

    function test_OnClaimed_WhenCallerIsNotTheRecipient_Reverts() public {
        PoolKey memory poolKey = _poolKey(FORK_TOKEN_ID);
        vm.expectRevert(abi.encodeWithSelector(CompoundingClaimExecutor.NotRecipient.selector, address(this)));
        executor.onClaimed(poolKey, FORK_TOKEN_ID, 0, 0);
    }

    function test_OnClaimed_WhenNoCompoundIsInProgress_Reverts() public {
        PoolKey memory poolKey = _poolKey(FORK_TOKEN_ID);
        vm.prank(address(recipient));
        vm.expectRevert(CompoundingClaimExecutor.NoCompoundInProgress.selector);
        executor.onClaimed(poolKey, FORK_TOKEN_ID, 0, 0);
    }

    function test_CollectAndCompound_IncreasesLiquidityAndKeepsNothing() public {
        _yoinkPosition(FORK_TOKEN_ID, address(splitter));
        PoolKey memory poolKey = _poolKey(FORK_TOKEN_ID);
        uint128 liquidityBefore = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);

        executor.collectAndCompound(FORK_TOKEN_ID, 0, 0);

        uint128 liquidityAfter = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);
        assertGt(liquidityAfter, liquidityBefore, "liquidity did not grow");

        // Everything the recipient paid out is either in the position or back with the splitter.
        assertEq(poolKey.currency0.balanceOf(address(executor)), 0, "executor kept currency0");
        assertEq(poolKey.currency1.balanceOf(address(executor)), 0, "executor kept currency1");
        assertEq(
            Currency.wrap(address(executor.weth9())).balanceOf(address(executor)), 0, "executor kept wrapped currency0"
        );
    }

    function test_CollectAndCompound_ClearsTheClaimedAttribution() public {
        _yoinkPosition(FORK_TOKEN_ID, address(splitter));

        executor.collectAndCompound(FORK_TOKEN_ID, 0, 0);

        (uint128 currency0Amount, uint128 currency1Amount) = recipient.amounts(FORK_TOKEN_ID);
        assertEq(currency0Amount, 0);
        assertEq(currency1Amount, 0);
    }

    function test_PreviewLiquidity_ReportsWhatTheAttributedAmountsWouldBuy() public {
        _yoinkPosition(FORK_TOKEN_ID, address(splitter));
        assertEq(executor.previewLiquidity(FORK_TOKEN_ID), 0, "nothing attributed yet");

        // Collect without compounding, leaving the recipient's share attributed and unclaimed.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = FORK_TOKEN_ID;
        splitter.collectFees(tokenIds);

        assertGt(executor.previewLiquidity(FORK_TOKEN_ID), 0, "attributed amounts buy no liquidity");
    }

    function test_CollectAndCompound_WhenLiquidityWouldNotGrowEnough_Reverts() public {
        CompoundingClaimRecipient strictRecipient =
            new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), type(uint128).max);
        FeeSplitter strictSplitter = _callbackSplitter(address(strictRecipient));
        CompoundingClaimExecutor strictExecutor = new CompoundingClaimExecutor(
            IFeeSplitter(address(strictSplitter)), IClaimableRecipient(address(strictRecipient)), LIQUIDITY_BUFFER_BPS
        );
        _yoinkPosition(FORK_TOKEN_ID, address(strictSplitter));

        vm.expectRevert();
        strictExecutor.collectAndCompound(FORK_TOKEN_ID, 0, 0);
    }

    function test_CollectAndCompound_WhenClaimFloorIsNotMet_Reverts() public {
        _yoinkPosition(FORK_TOKEN_ID, address(splitter));

        vm.expectRevert();
        executor.collectAndCompound(FORK_TOKEN_ID, type(uint128).max, 0);
    }

    function _callbackSplitter(address _recipient) internal returns (FeeSplitter feeSplitter) {
        FeeSplit[] memory splits = new FeeSplit[](1);
        splits[0] = FeeSplit({recipient: _recipient, nativeBps: 10_000, tokenBps: 10_000, useCallback: true});
        feeSplitter = new FeeSplitter(IPositionManager(POSITION_MANAGER), splits);
    }
}
