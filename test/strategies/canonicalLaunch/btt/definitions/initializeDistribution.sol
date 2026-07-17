// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    CanonicalLaunchTestBase,
    MockCanonicalShortTransferToken,
    MockCanonicalSixDecimalToken
} from "../../base/CanonicalLaunchTestBase.sol";
import {CanonicalLaunchStrategy} from "../../../../../src/strategies/CanonicalLaunchStrategy.sol";
import {DirectLaunchParameters} from "../../../../../src/libraries/DirectLaunchParams.sol";
import {BuybackAndBurnPositionRecipient} from "../../../../../src/periphery/BuybackAndBurnPositionRecipient.sol";
import {DutchDecayConfig} from "../../../../../src/periphery/modules/DutchDecayFeeModule.sol";
import {LaunchConfig} from "../../../../../src/interfaces/ILaunchHook.sol";
import {PositionDefinition} from "../../../../../src/types/PositionPlannerTypes.sol";
import {MockERC20} from "../../../../mocks/MockERC20.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @title InitializeDistributionTest
/// @notice BTT tests for CanonicalLaunchStrategy.initializeDistribution
///
/// initializeDistribution
/// ├── when the caller is not the launcher
/// │   └── it reverts with OnlyLauncher
/// ├── when configData is not empty
/// │   └── it reverts with UnexpectedConfigData
/// ├── when the distribution amount is not the canonical supply
/// │   └── it reverts with InvalidSupply
/// ├── when the token supply is not the canonical supply
/// │   └── it reverts with InvalidSupply
/// ├── when the token does not use 18 decimals
/// │   └── it reverts with InvalidTokenDecimals
/// ├── when the received token amount is not exact
/// │   └── it reverts with TokenAmountMismatch
/// ├── when the underlying strategy does not consume its allowance
/// │   └── it reverts with AllowanceNotFullyConsumed
/// ├── when the underlying strategy returns tokens
/// │   └── it reverts with UnplacedTokens
/// └── when the launch is valid
///     ├── it preserves preexisting balances
///     ├── it deploys the permanent fee recipient
///     ├── it delegates the canonical launch configuration
///     └── it emits CanonicalTokenLaunched
contract InitializeDistributionTest is CanonicalLaunchTestBase {
    function test_WhenCallerIsNotLauncher() public {
        vm.expectRevert(CanonicalLaunchStrategy.OnlyLauncher.selector);
        vm.prank(makeAddr("unauthorized"));
        strategy.initializeDistribution(address(1), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenConfigDataIsNotEmpty() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);

        vm.expectRevert(CanonicalLaunchStrategy.UnexpectedConfigData.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, hex"01", bytes32(0));
    }

    function test_WhenDistributionAmountIsNotCanonicalSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);

        vm.expectRevert(CanonicalLaunchStrategy.InvalidSupply.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY - 1, bytes(""), bytes32(0));
    }

    function test_WhenTokenSupplyIsNotCanonicalSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY + 1);

        vm.expectRevert(CanonicalLaunchStrategy.InvalidSupply.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenTokenDoesNotUse18Decimals() public {
        MockCanonicalSixDecimalToken token = new MockCanonicalSixDecimalToken(TOTAL_SUPPLY, address(this));

        vm.expectRevert(CanonicalLaunchStrategy.InvalidTokenDecimals.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenReceivedTokenAmountIsNotExact() public {
        MockCanonicalShortTransferToken token = new MockCanonicalShortTransferToken(TOTAL_SUPPLY, address(this));
        token.approve(address(strategy), TOTAL_SUPPLY);

        vm.expectRevert(CanonicalLaunchStrategy.TokenAmountMismatch.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenUnderlyingStrategyDoesNotConsumeAllowance() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        directLaunchStrategy.setBehavior(1, 0);
        token.approve(address(strategy), TOTAL_SUPPLY);

        vm.expectRevert(CanonicalLaunchStrategy.AllowanceNotFullyConsumed.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenUnderlyingStrategyReturnsTokens() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        directLaunchStrategy.setBehavior(0, 1);
        token.approve(address(strategy), TOTAL_SUPPLY);

        vm.expectRevert(CanonicalLaunchStrategy.UnplacedTokens.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenLaunchIsValid_preservesPreexistingBalance() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        deal(address(token), address(strategy), 1, false);

        _initialize(token, TOTAL_SUPPLY, bytes(""));

        assertEq(token.balanceOf(address(strategy)), 1);
    }

    function test_WhenLaunchIsValid_deploysRecipientDelegatesConfigurationAndEmitsEvent() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 launchBlock = block.number;
        address positionRecipient = vm.computeCreateAddress(address(strategy), 1);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(launchHook)
        });

        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectEmit(true, true, true, true, address(strategy));
        emit CanonicalLaunchStrategy.CanonicalTokenLaunched(key.toId(), address(token), positionRecipient);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(uint256(1)));

        BuybackAndBurnPositionRecipient recipient = BuybackAndBurnPositionRecipient(payable(positionRecipient));
        assertEq(recipient.token(), address(token));
        assertEq(recipient.currency(), address(0));
        assertEq(recipient.operator(), address(0));
        assertEq(address(recipient.positionManager()), address(positionManager));
        assertEq(recipient.timelockBlockNumber(), type(uint256).max);
        assertEq(recipient.minTokenBurnAmount(), TOTAL_SUPPLY / 2_000);

        assertEq(directLaunchStrategy.lastToken(), address(token));
        assertEq(directLaunchStrategy.lastTotalSupply(), TOTAL_SUPPLY);
        assertEq(directLaunchStrategy.lastSalt(), bytes32(0));
        assertEq(token.allowance(address(strategy), address(directLaunchStrategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);

        DirectLaunchParameters memory params =
            abi.decode(directLaunchStrategy.lastConfigData(), (DirectLaunchParameters));
        assertEq(params.currency, address(0));
        assertEq(params.initialSqrtPriceX96, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
        assertEq(params.recipient, BURN_ADDRESS);
        assertEq(params.positionRecipient, positionRecipient);
        assertEq(params.poolParameters.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(params.poolParameters.tickSpacing, strategy.TICK_SPACING());
        assertEq(params.poolParameters.hook, launchHook);

        PositionDefinition[] memory positions = abi.decode(params.positionDefinitions, (PositionDefinition[]));
        assertEq(positions.length, 1);
        assertEq(positions[0].offsetLower, TickMath.minUsableTick(strategy.TICK_SPACING()) - INITIAL_TICK);
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
    }
}
