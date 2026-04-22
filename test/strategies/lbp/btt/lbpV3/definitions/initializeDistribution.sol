// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPStrategyConfiguration} from "src/interfaces/ILBPStrategyConfiguration.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

/// @title InitializeDistributionTest
/// @notice BTT tests for LBPStrategy.initializeDistribution
///
/// initializeDistribution
/// ├── when breakpoint config is invalid (empty, rate 0, >1e7, <min)
/// │   └── it reverts with InvalidBreakpointConfiguration
/// ├── when tickSpacing is out of bounds
/// │   └── it reverts with InvalidTickSpacing
/// ├── when fee > MAX_LP_FEE
/// │   └── it reverts with InvalidFee
/// ├── when positionRecipient is reserved
/// │   └── it reverts with InvalidPositionRecipient
/// └── when migrator params are valid
///     ├── when initializer.fundsRecipient != strategy
///     │   └── it reverts with InvalidRecipient
///     ├── when initializer.endBlock >= migrationBlock
///     │   └── it reverts with InvalidEndBlock
///     ├── when initializer.custodyTokens mismatch
///     │   └── it reverts with InvalidCustodySupply
///     └── when initializer is valid
///         ├── it stores the identifier
///         └── it emits InitializerCreated
contract InitializeDistributionTest is LBPStrategyTestBase {
    function test_WhenBreakpointsEmpty() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](0);

        vm.expectRevert(ILBPStrategyConfiguration.InvalidBreakpointConfiguration.selector);
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, bp, hex""), bytes32(0)
        );
    }

    function test_WhenBreakpointRateIsZero() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](1);
        bp[0] = ILBPStrategy.Breakpoint({threshold: 0, rate: 0});

        vm.expectRevert(ILBPStrategyConfiguration.InvalidBreakpointConfiguration.selector);
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, bp, hex""), bytes32(0)
        );
    }

    function test_WhenBreakpointRateIsOver100Percent(uint24 _rate) public {
        _rate = uint24(bound(_rate, 1e7 + 1, type(uint24).max));

        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](1);
        bp[0] = ILBPStrategy.Breakpoint({threshold: 0, rate: _rate});

        vm.expectRevert(ILBPStrategyConfiguration.InvalidBreakpointConfiguration.selector);
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, bp, hex""), bytes32(0)
        );
    }

    function test_WhenBreakpointRateIsBelowMinimum(uint24 _minSplit, uint24 _rate) public {
        _minSplit = uint24(bound(_minSplit, 2, 10_000));
        _rate = uint24(bound(_rate, 1, _minSplit - 1));

        strategy.setMinSplitForLp(_minSplit);

        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](1);
        bp[0] = ILBPStrategy.Breakpoint({threshold: 0, rate: _rate});

        vm.expectRevert(ILBPStrategyConfiguration.InvalidBreakpointConfiguration.selector);
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, bp, hex""), bytes32(0)
        );
    }

    function test_WhenNonLastBreakpointThresholdIsZero() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](2);
        bp[0] = ILBPStrategy.Breakpoint({threshold: 0, rate: 5e6}); // threshold 0 on non-last
        bp[1] = ILBPStrategy.Breakpoint({threshold: 0, rate: 3e6});

        vm.expectRevert(ILBPStrategyConfiguration.InvalidBreakpointConfiguration.selector);
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, bp, hex""), bytes32(0)
        );
    }

    function test_WhenBreakpointThresholdsNotAscending() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](3);
        bp[0] = ILBPStrategy.Breakpoint({threshold: 100e18, rate: 7e6});
        bp[1] = ILBPStrategy.Breakpoint({threshold: 50e18, rate: 5e6}); // not ascending
        bp[2] = ILBPStrategy.Breakpoint({threshold: 0, rate: 3e6});

        vm.expectRevert(ILBPStrategyConfiguration.InvalidBreakpointConfiguration.selector);
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, bp, hex""), bytes32(0)
        );
    }

    modifier whenBreakpointConfigIsValid() {
        _;
    }

    function test_WhenTickSpacingIsOutOfBounds(int24 _tickSpacing) public whenBreakpointConfigIsValid {
        vm.assume(_tickSpacing > TickMath.MAX_TICK_SPACING || _tickSpacing < TickMath.MIN_TICK_SPACING);

        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        mp.poolTickSpacing = _tickSpacing;

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategy.InvalidTickSpacing.selector,
                _tickSpacing,
                TickMath.MIN_TICK_SPACING,
                TickMath.MAX_TICK_SPACING
            )
        );
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, _defaultBreakpoints(), hex""), bytes32(0)
        );
    }

    modifier whenTickSpacingIsValid() {
        _;
    }

    function test_WhenFeeIsAboveMax(uint24 _fee) public whenBreakpointConfigIsValid whenTickSpacingIsValid {
        _fee = uint24(bound(_fee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));

        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        mp.poolLPFee = _fee;

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidFee.selector, _fee, LPFeeLibrary.MAX_LP_FEE));
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, _defaultBreakpoints(), hex""), bytes32(0)
        );
    }

    modifier whenFeeIsValid() {
        _;
    }

    function test_WhenPositionRecipientIsReserved(uint256 _seed)
        public
        whenBreakpointConfigIsValid
        whenTickSpacingIsValid
        whenFeeIsValid
    {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();

        if (_seed % 3 == 0) {
            mp.lpPositionRecipient = address(0);
        } else if (_seed % 3 == 1) {
            mp.lpPositionRecipient = ActionConstants.MSG_SENDER;
        } else {
            mp.lpPositionRecipient = ActionConstants.ADDRESS_THIS;
        }

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidPositionRecipient.selector, mp.lpPositionRecipient));
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, _defaultBreakpoints(), hex""), bytes32(0)
        );
    }

    modifier whenPositionRecipientIsValid() {
        _;
    }

    modifier whenMigratorParamsAreValid() {
        _;
    }

    function test_WhenInitializerFundsRecipientIsWrong() public whenMigratorParamsAreValid {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();

        MockLBPInitializer badInit = new MockLBPInitializer(
            address(token),
            address(0),
            0,
            uint128(mp.supplyForLP + mp.custodyTokens),
            address(strategy),
            makeAddr("wrongRecipient"),
            0,
            uint64(block.number) + 50
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidRecipient.selector, address(strategy)));
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, _defaultBreakpoints(), hex""), bytes32(0)
        );
    }

    function test_WhenInitializerEndBlockGTEMigrationBlock() public whenMigratorParamsAreValid {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();

        MockLBPInitializer badInit = new MockLBPInitializer(
            address(token),
            address(0),
            0,
            uint128(mp.supplyForLP + mp.custodyTokens),
            address(strategy),
            address(strategy),
            0,
            uint64(mp.migrationBlock)
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.InvalidEndBlock.selector, mp.migrationBlock, mp.migrationBlock)
        );
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, _defaultBreakpoints(), hex""), bytes32(0)
        );
    }

    function test_WhenInitializerCustodyTokensMismatch() public whenMigratorParamsAreValid {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();

        MockLBPInitializer badInit = new MockLBPInitializer(
            address(token), address(0), 0, 999, address(strategy), address(strategy), 0, uint64(block.number) + 50
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        uint256 expected = uint256(mp.supplyForLP) + uint256(mp.custodyTokens);
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCustodySupply.selector, 999, expected));
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, _defaultBreakpoints(), hex""), bytes32(0)
        );
    }

    modifier whenInitializerIsValid() {
        _;
    }

    function test_WhenInitializerIsNew() public whenMigratorParamsAreValid whenInitializerIsValid {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        ILBPStrategy.Breakpoint[] memory bp = _defaultBreakpoints();
        factory.setCustodyTokens(mp.supplyForLP + mp.custodyTokens);

        vm.recordLogs();
        strategy.initializeDistribution(
            address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, bp, hex""), bytes32(0)
        );

        MockLBPInitializer initializer = factory.deployedInitializer();

        assertNotEq(address(initializer), address(0));

        // Verify migration parameters were stored correctly
        (ILBPStrategy.MigratorParameters memory storedParams) =
            strategy.initializers(ILBPInitializer(address(initializer)));
        assertEq(storedParams.migrationBlock, mp.migrationBlock);
        assertEq(storedParams.poolLPFee, mp.poolLPFee);
        assertEq(storedParams.poolTickSpacing, mp.poolTickSpacing);
        assertEq(storedParams.supplyForLP, mp.supplyForLP);
    }
}
