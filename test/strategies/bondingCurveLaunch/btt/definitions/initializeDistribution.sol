// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    BondingCurveLaunchTestBase,
    MockBondingShortTransferToken,
    MockBondingSixDecimalToken
} from "../../base/BondingCurveLaunchTestBase.sol";
import {BondingCurveLaunchStrategy} from "../../../../../src/strategies/BondingCurveLaunchStrategy.sol";
import {IDirectLaunchStrategy} from "../../../../../src/interfaces/IDirectLaunchStrategy.sol";
import {BuybackAndBurnPositionRecipient} from "../../../../../src/periphery/BuybackAndBurnPositionRecipient.sol";
import {DirectLaunchParameters} from "../../../../../src/libraries/DirectLaunchParams.sol";
import {BondingCurveHookConfig} from "../../../../../src/interfaces/IBondingCurveLaunchHook.sol";
import {LaunchConfig} from "../../../../../src/interfaces/ILaunchHook.sol";
import {DutchDecayConfig} from "../../../../../src/periphery/modules/DutchDecayFeeModule.sol";
import {PositionDefinition} from "../../../../../src/types/PositionPlannerTypes.sol";
import {MockERC20} from "../../../../mocks/MockERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
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
///     ├── it builds one finite curve position
///     └── it configures permanent full-range graduation
contract InitializeDistributionTest is BondingCurveLaunchTestBase {
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
        MockERC20 token = _deployToken(TOTAL_SUPPLY + 1);

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
            abi.encodeWithSelector(IDirectLaunchStrategy.TokenAmountMismatch.selector, TOTAL_SUPPLY - 1, TOTAL_SUPPLY)
        );
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenLaunchIsValid_preservesPreexistingBalance() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        deal(address(token), address(strategy), 1, false);

        _initialize(token, TOTAL_SUPPLY, bytes(""));

        assertEq(token.balanceOf(address(strategy)), 1);
    }

    function test_WhenLaunchIsValid_delegatesCurveAndGraduationConfiguration() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 launchBlock = block.number;
        address finalPositionRecipient = vm.computeCreateAddress(address(strategy), 1);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(address(launchHook))
        });

        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectEmit(true, true, true, true, address(strategy));
        emit BondingCurveLaunchStrategy.BondingCurveTokenLaunched(
            key.toId(), address(token), finalPositionRecipient, strategy.curveSupply(), strategy.reserveSupply()
        );
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(uint256(1)));

        assertEq(token.balanceOf(address(launchHook)), strategy.reserveSupply());
        assertEq(token.balanceOf(address(strategy)), 0);

        BuybackAndBurnPositionRecipient recipient = BuybackAndBurnPositionRecipient(payable(finalPositionRecipient));
        assertEq(recipient.token(), address(token));
        assertEq(recipient.currency(), address(0));
        assertEq(recipient.operator(), address(0));
        assertEq(recipient.timelockBlockNumber(), type(uint256).max);
        assertEq(recipient.minTokenBurnAmount(), TOTAL_SUPPLY / 2_000);

        assertEq(strategyHarness.lastToken(), address(token));
        assertEq(strategyHarness.lastTotalSupply(), strategy.curveSupply());

        DirectLaunchParameters memory params = abi.decode(strategyHarness.lastConfigData(), (DirectLaunchParameters));
        assertEq(params.currency, address(0));
        assertEq(params.initialSqrtPriceX96, strategy.initialSqrtPriceX96());
        assertEq(params.recipient, address(0xdead));
        assertEq(params.positionRecipient, address(launchHook));
        assertEq(params.poolParameters.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(params.poolParameters.tickSpacing, strategy.TICK_SPACING());
        assertEq(params.poolParameters.hook, address(launchHook));

        PositionDefinition[] memory positions = abi.decode(params.positionDefinitions, (PositionDefinition[]));
        assertEq(positions.length, 1);
        assertEq(positions[0].offsetLower, GRADUATION_TICK - INITIAL_TICK);
        assertEq(positions[0].offsetUpper, 0);
        assertEq(positions[0].weight, 10_000_000);
        assertEq(positions[0].overridePositionRecipient, address(0));

        LaunchConfig memory config = abi.decode(params.launchConfig, (LaunchConfig));
        assertEq(config.swapStartBlock, launchBlock);
        assertEq(config.windowEndBlock, launchBlock + strategy.DECAY_BLOCKS());
        assertEq(config.baseFee, 0);
        assertFalse(config.tokenIsCurrency0);
        assertEq(config.module, dynamicFeeModule);

        DutchDecayConfig memory decay = abi.decode(config.moduleConfig, (DutchDecayConfig));
        assertEq(decay.startFee, strategy.START_FEE());
        assertEq(decay.endFee, 0);
        assertEq(decay.decayBlocks, strategy.DECAY_BLOCKS());
        assertTrue(decay.taxBothDirections);

        BondingCurveHookConfig memory hookConfig = abi.decode(config.hookConfig, (BondingCurveHookConfig));
        assertEq(hookConfig.reserveTokenAmount, strategy.reserveSupply());
        assertEq(hookConfig.finalPositionRecipient, finalPositionRecipient);
        assertEq(hookConfig.graduationSqrtPriceX96, strategy.graduationSqrtPriceX96());
        assertEq(hookConfig.curveTickLower, GRADUATION_TICK);
        assertEq(hookConfig.curveTickUpper, INITIAL_TICK);
    }
}
