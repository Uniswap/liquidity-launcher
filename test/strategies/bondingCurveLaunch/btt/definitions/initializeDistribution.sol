// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    BondingCurveLaunchTestBase,
    MockBondingShortTransferToken,
    MockBondingSixDecimalToken
} from "../../base/BondingCurveLaunchTestBase.sol";
import {BondingCurveLaunchStrategy} from "../../../../../src/strategies/BondingCurveLaunchStrategy.sol";
import {BondingCurveHookConfig, BondingCurvePhase} from "../../../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {MockERC20} from "../../../../mocks/MockERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title InitializeDistributionTest
/// @notice BTT tests for BondingCurveLaunchStrategy.initializeDistribution
///
/// initializeDistribution
/// ├── when the caller is not the launcher
/// │   └── it reverts with OnlyLauncher
/// ├── when configData is not empty
/// │   └── it reverts with UnexpectedConfigData
/// ├── when either supply is not the fixed supply
/// │   └── it reverts with InvalidSupply
/// ├── when the token does not use 18 decimals
/// │   └── it reverts with InvalidTokenDecimals
/// ├── when the received token amount is not exact
/// │   └── it reverts with TokenAmountMismatch
/// └── when the launch is valid
///     ├── it preserves preexisting balances
///     ├── it reserves the derived supply in the launch hook
///     ├── it builds one finite curve position owned by the hook
///     └── it configures permanent full-range graduation
contract InitializeDistributionTest is BondingCurveLaunchTestBase {
    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(address(launchHook))
        });
    }

    function test_WhenCallerIsNotLauncher() public {
        vm.expectRevert(BondingCurveLaunchStrategy.OnlyLauncher.selector);
        vm.prank(makeAddr("unauthorized"));
        strategy.initializeDistribution(address(1), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenConfigDataIsNotEmpty() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        vm.expectRevert(BondingCurveLaunchStrategy.UnexpectedConfigData.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, hex"01", bytes32(0));
    }

    function test_WhenDistributionAmountIsNotFixedSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        vm.expectRevert(BondingCurveLaunchStrategy.InvalidSupply.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY - 1, bytes(""), bytes32(0));
    }

    function test_WhenTokenSupplyIsNotFixedSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY - 1);
        vm.expectRevert(BondingCurveLaunchStrategy.InvalidSupply.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenTokenDoesNotUse18Decimals() public {
        MockBondingSixDecimalToken token = new MockBondingSixDecimalToken(TOTAL_SUPPLY, address(this));
        vm.expectRevert(BondingCurveLaunchStrategy.InvalidTokenDecimals.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenReceivedTokenAmountIsNotExact() public {
        MockBondingShortTransferToken token = new MockBondingShortTransferToken(TOTAL_SUPPLY, address(this));
        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(
                BondingCurveLaunchStrategy.TokenAmountMismatch.selector, TOTAL_SUPPLY - 1, TOTAL_SUPPLY
            )
        );
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenLaunchIsValid_preservesPreexistingBalance() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        // Strand a preexisting balance on the strategy (without changing total supply); the launch's
        // dust sweep must only burn what it added, leaving the preexisting balance intact.
        deal(address(token), address(strategy), 1 ether, false);
        _initialize(token, TOTAL_SUPPLY, bytes(""));
        assertEq(token.balanceOf(address(strategy)), 1 ether);
    }

    function test_WhenLaunchIsValid_delegatesCurveAndGraduationConfiguration() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        PoolKey memory key = _key(address(token));
        uint256 curveTokenId = POSITION_MANAGER.nextTokenId();

        _initialize(token, TOTAL_SUPPLY, bytes(""));

        // Curve is live and its NFT is custodied by the hook.
        assertEq(uint256(launchHook.bondingCurvePhase(key.toId())), uint256(BondingCurvePhase.Active));
        assertEq(launchHook.curveTokenId(key.toId()), curveTokenId);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(curveTokenId), address(launchHook));

        // Reserve is held by the hook for graduation.
        assertGe(token.balanceOf(address(launchHook)), strategy.reserveSupply());

        // Graduation config was registered.
        BondingCurveHookConfig memory config = launchHook.bondingCurveConfig(key.toId());
        assertEq(config.reserveTokenAmount, strategy.reserveSupply());
        assertEq(config.curveTickLower, GRADUATION_TICK);
        assertEq(config.curveTickUpper, INITIAL_TICK);
        assertEq(config.module, dynamicFeeModule);
        assertTrue(config.finalPositionRecipient != address(0));
    }
}
