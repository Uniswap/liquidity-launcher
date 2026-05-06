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
import {MockERC20} from "test/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

/// @title InitializeDistributionTest
/// @notice BTT tests for LBPStrategy.initializeDistribution
///
/// initializeDistribution
/// ├── when breakpoint length is invalid (empty)
/// │   └── it reverts with InvalidBreakpointLength
/// ├── when breakpoint rate is invalid (>1e7)
/// │   └── it reverts with InvalidBreakpointRate
/// ├── when breakpoint threshold is invalid (0, not ascending)
/// │   └── it reverts with InvalidBreakpointThreshold
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
    struct NotAscendingParams {
        uint24 rate0;
        uint24 rate1;
        uint24 rate2;
        uint128 threshold0;
        uint128 threshold1;
        MigrationFuzzParams fuzzParams;
    }

    struct TooManyBreakpointsParams {
        uint24 rate0;
        uint24 rate1;
        uint24 rate2;
        uint24 rate3;
        uint128 threshold0;
        uint128 threshold1;
        uint128 threshold2;
        MigrationFuzzParams fuzzParams;
    }

    function test_WhenBreakpointsEmpty(MigrationFuzzParams memory p) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](0);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidBreakpointLength.selector, 0));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenFirstBreakpointLowerThresholdIsNonZero(
        uint128 _threshold,
        uint24 _rate,
        MigrationFuzzParams memory p
    ) public {
        _threshold = uint128(bound(_threshold, 1, type(uint128).max));
        _rate = uint24(bound(_rate, 1, strategy.MAX_BRACKET_RATE()));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](1);
        bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: _threshold, rate: _rate});

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidBreakpointThreshold.selector, _threshold)
        );
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenBreakpointRateIsOver100Percent(uint24 _rate, MigrationFuzzParams memory p) public {
        _rate = uint24(bound(_rate, strategy.MAX_BRACKET_RATE() + 1, type(uint24).max));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](1);
        bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: _rate});

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidBreakpointRate.selector, _rate));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenNonLastBreakpointThresholdIsZero(uint24 _rate0, uint24 _rate1, MigrationFuzzParams memory p)
        public
    {
        _rate0 = uint24(bound(_rate0, 1, strategy.MAX_BRACKET_RATE()));
        _rate1 = uint24(bound(_rate1, 1, strategy.MAX_BRACKET_RATE()));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](2);
        bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: _rate0});
        bp[1] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: _rate1});

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidBreakpointThreshold.selector, 0));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenBreakpointThresholdsNotAscending(NotAscendingParams memory p) public {
        p.rate0 = uint24(bound(p.rate0, 1, strategy.MAX_BRACKET_RATE()));
        p.rate1 = uint24(bound(p.rate1, 1, strategy.MAX_BRACKET_RATE()));
        p.rate2 = uint24(bound(p.rate2, 1, strategy.MAX_BRACKET_RATE()));
        p.threshold0 = uint128(bound(p.threshold0, 2, type(uint128).max));
        p.threshold1 = uint128(bound(p.threshold1, 1, p.threshold0 - 1));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p.fuzzParams);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](3);
        bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: p.rate0});
        bp[1] = ILBPStrategy.Breakpoint({lowerThreshold: p.threshold0, rate: p.rate1});
        bp[2] = ILBPStrategy.Breakpoint({lowerThreshold: p.threshold1, rate: p.rate2});

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidBreakpointThreshold.selector, p.threshold1)
        );
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    modifier whenBreakpointConfigIsValid() {
        _;
    }

    function test_WhenBreakpointsTooMany(TooManyBreakpointsParams memory p) public {
        p.rate0 = uint24(bound(p.rate0, 1, strategy.MAX_BRACKET_RATE()));
        p.rate1 = uint24(bound(p.rate1, 1, strategy.MAX_BRACKET_RATE()));
        p.rate2 = uint24(bound(p.rate2, 1, strategy.MAX_BRACKET_RATE()));
        p.rate3 = uint24(bound(p.rate3, 1, strategy.MAX_BRACKET_RATE()));
        p.threshold0 = uint128(bound(p.threshold0, 1, type(uint128).max - 2));
        p.threshold1 = uint128(bound(p.threshold1, p.threshold0 + 1, type(uint128).max - 1));
        p.threshold2 = uint128(bound(p.threshold2, p.threshold1 + 1, type(uint128).max));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p.fuzzParams);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](4);
        bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: p.rate0});
        bp[1] = ILBPStrategy.Breakpoint({lowerThreshold: p.threshold0, rate: p.rate1});
        bp[2] = ILBPStrategy.Breakpoint({lowerThreshold: p.threshold1, rate: p.rate2});
        bp[3] = ILBPStrategy.Breakpoint({lowerThreshold: p.threshold2, rate: p.rate3});

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidBreakpointLength.selector, 4));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenBreakpointThresholdsAreEqual(
        uint24 _rate0,
        uint24 _rate1,
        uint24 _rate2,
        uint128 _threshold,
        MigrationFuzzParams memory p
    ) public {
        _rate0 = uint24(bound(_rate0, 1, strategy.MAX_BRACKET_RATE()));
        _rate1 = uint24(bound(_rate1, 1, strategy.MAX_BRACKET_RATE()));
        _rate2 = uint24(bound(_rate2, 1, strategy.MAX_BRACKET_RATE()));
        _threshold = uint128(bound(_threshold, 1, type(uint128).max));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](3);
        bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: _rate0});
        bp[1] = ILBPStrategy.Breakpoint({lowerThreshold: _threshold, rate: _rate1});
        bp[2] = ILBPStrategy.Breakpoint({lowerThreshold: _threshold, rate: _rate2});

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyConfiguration.InvalidBreakpointThreshold.selector, _threshold)
        );
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenBreakpointRateExactlyAtMaxBracketRate(MigrationFuzzParams memory p) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        ILBPStrategy.Breakpoint[] memory bp = new ILBPStrategy.Breakpoint[](1);
        bp[0] = ILBPStrategy.Breakpoint({lowerThreshold: 0, rate: strategy.MAX_BRACKET_RATE()});

        bytes memory initializerParams = abi.encode(mp.supplyForLP, endBlock);
        // Should not revert — rate is exactly MAX_BRACKET_RATE
        strategy.initializeDistribution(
            address(token), totalSupply, _encodeConfigData(mp, bp, initializerParams), bytes32(0)
        );
    }

    function test_WhenTickSpacingIsOutOfBounds(int24 _tickSpacing, MigrationFuzzParams memory p)
        public
        whenBreakpointConfigIsValid
    {
        // it reverts with {InvalidTickSpacing}
        vm.assume(_tickSpacing > TickMath.MAX_TICK_SPACING || _tickSpacing < TickMath.MIN_TICK_SPACING);

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        mp.poolTickSpacing = _tickSpacing;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategy.InvalidTickSpacing.selector,
                _tickSpacing,
                TickMath.MIN_TICK_SPACING,
                TickMath.MAX_TICK_SPACING
            )
        );
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenTickSpacingIsValid() {
        _;
    }

    function test_WhenFeeIsAboveMax(uint24 _fee, MigrationFuzzParams memory p)
        public
        whenBreakpointConfigIsValid
        whenTickSpacingIsValid
    {
        // it reverts with {InvalidFee}
        _fee = uint24(bound(_fee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        mp.poolLPFee = _fee;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidFee.selector, _fee, LPFeeLibrary.MAX_LP_FEE));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenFeeIsValid() {
        _;
    }

    function test_WhenPositionRecipientIsReserved(uint256 _seed, MigrationFuzzParams memory p)
        public
        whenBreakpointConfigIsValid
        whenTickSpacingIsValid
        whenFeeIsValid
    {
        // it reverts with {InvalidPositionRecipient}
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        if (_seed % 3 == 0) {
            mp.lpPositionRecipient = address(0);
        } else if (_seed % 3 == 1) {
            mp.lpPositionRecipient = ActionConstants.MSG_SENDER;
        } else {
            mp.lpPositionRecipient = ActionConstants.ADDRESS_THIS;
        }

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidPositionRecipient.selector, mp.lpPositionRecipient));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenPositionRecipientIsValid() {
        _;
    }

    modifier whenMigratorParamsAreValid() {
        _;
    }

    function test_WhenInitializerFundsRecipientIsWrong(address _wrongRecipient, MigrationFuzzParams memory p)
        public
        whenMigratorParamsAreValid
    {
        // it reverts with {InvalidRecipient}
        vm.assume(_wrongRecipient != address(strategy));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        MockLBPInitializer badInit = new MockLBPInitializer(
            address(1), address(0), 0, mp.supplyForLP, address(strategy), _wrongRecipient, 0, endBlock
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidRecipient.selector, address(strategy)));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenInitializerEndBlockGTEMigrationBlock(uint64 _endBlockOffset, MigrationFuzzParams memory p)
        public
        whenMigratorParamsAreValid
    {
        // it reverts with {InvalidEndBlock}
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        // endBlock >= migrationBlock
        uint64 endBlock = uint64(bound(_endBlockOffset, mp.migrationBlock, type(uint64).max));

        MockLBPInitializer badInit = new MockLBPInitializer(
            address(1), address(0), 0, mp.supplyForLP, address(strategy), address(strategy), 0, endBlock
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidEndBlock.selector, endBlock, mp.migrationBlock));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenInitializerCustodyTokensMismatch(uint128 _wrongCustody, MigrationFuzzParams memory p)
        public
        whenMigratorParamsAreValid
    {
        // it reverts with {InvalidCustodySupply}
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        uint128 expectedCustody = mp.supplyForLP;
        vm.assume(_wrongCustody != expectedCustody);

        MockLBPInitializer badInit = new MockLBPInitializer(
            address(1), address(0), 0, _wrongCustody, address(strategy), address(strategy), 0, endBlock
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.InvalidCustodySupply.selector, _wrongCustody, expectedCustody)
        );
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenInitializerIsValid() {
        _;
    }

    function test_WhenInitializerIsNew(MigrationFuzzParams memory p)
        public
        whenMigratorParamsAreValid
        whenInitializerIsValid
    {
        // it saves the parameters to storage
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock);

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
