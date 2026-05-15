// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {MigratorParams, MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {IInitializerHook} from "src/interfaces/IInitializerHook.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PositionPlanner} from "src/libraries/PositionPlanner.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";

contract MockInitializerHook {
    address public immutable authorized;

    constructor(address _authorized) {
        authorized = _authorized;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IInitializerHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title InitializeDistributionTest
/// @notice BTT tests for LBPStrategy.initializeDistribution
///
/// initializeDistribution
/// ├── when hook authorized address is not strategy
/// │   └── it reverts with InvalidHook
/// ├── when bracket count is invalid (empty or too many)
/// │   └── it reverts with InvalidBracketCount
/// ├── when bracket rate is invalid (>1e7)
/// │   └── it reverts with InvalidBracketRate
/// ├── when bracket lowerThreshold is invalid (first ≠ 0, zero non-first, or not strictly ascending)
/// │   └── it reverts with InvalidBracketThreshold
/// ├── when tickSpacing is out of bounds
/// │   └── it reverts with InvalidTickSpacing
/// ├── when fee > MAX_LP_FEE
/// │   └── it reverts with InvalidFee
/// ├── when fee is the dynamic fee flag
/// │   └── it stores the migration parameters
/// ├── when positionRecipient is reserved
/// │   └── it reverts with InvalidPositionRecipient
/// ├── when supplyForLP > int128.max
/// │   └── it reverts with InvalidSupplyForLp
/// ├── when position definitions contain invalid tick bounds
/// │   └── it reverts with InvalidTickBounds
/// ├── when position definitions exceed the max position count
/// │   └── it reverts with TooManyPositions
/// └── when migrator params are valid
///     ├── when initializer.fundsRecipient != strategy
///     │   └── it reverts with InvalidRecipient
///     ├── when initializer.endBlock >= migrationBlock
///     │   └── it reverts with InvalidEndBlock
///     └── when initializer is valid
///         ├── it stores the migration parameters
///         └── it emits InitializerCreated
contract InitializeDistributionTest is LBPStrategyTestBase {
    function test_WhenHookAuthorizedAddressIsNotStrategy(address _authorized, MigrationFuzzParams memory p) public {
        vm.assume(_authorized != address(strategy));

        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        mp.hook = address(new MockInitializerHook(_authorized));

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory initializerParams = abi.encode(mp.supplyForLP, endBlock);
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), initializerParams);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidHook.selector, mp.hook));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    function test_WhenScheduleEmpty(MigrationFuzzParams memory p) public {
        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](0);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidBracketCount.selector, 0));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenFirstBracketLowerThresholdIsNonZero(
        uint128 _threshold,
        uint24 _rate,
        MigrationFuzzParams memory p
    ) public {
        _threshold = uint128(bound(_threshold, 1, type(uint128).max));
        _rate = uint24(bound(_rate, 1, MigratorParams.MAX_BRACKET_RATE));

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: _threshold, rate: _rate});

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidBracketThreshold.selector, _threshold));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenBracketRateIsOver100Percent(uint24 _rate, MigrationFuzzParams memory p) public {
        _rate = uint24(bound(_rate, MigratorParams.MAX_BRACKET_RATE + 1, type(uint24).max));

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: _rate});

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidBracketRate.selector, _rate));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenNonLastBracketLowerThresholdIsZero(uint24 _rate0, uint24 _rate1, MigrationFuzzParams memory p)
        public
    {
        _rate0 = uint24(bound(_rate0, 1, MigratorParams.MAX_BRACKET_RATE));
        _rate1 = uint24(bound(_rate1, 1, MigratorParams.MAX_BRACKET_RATE));

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](2);
        // Non-first bracket with lowerThreshold == previous fails the strict-ascend check on bp[1]
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: _rate0});
        bp[1] = LiquidityAllocationBracket({lowerThreshold: 0, rate: _rate1});

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidBracketThreshold.selector, 0));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenBracketLowerThresholdsNotAscending(MigrationFuzzParams memory p) public {
        uint24 rate0 = uint24(bound(p.bpParams.rate0, 1, MigratorParams.MAX_BRACKET_RATE));
        uint24 rate1 = uint24(bound(p.bpParams.rate1, 1, MigratorParams.MAX_BRACKET_RATE));
        uint24 rate2 = uint24(bound(p.bpParams.rate2, 1, MigratorParams.MAX_BRACKET_RATE));
        uint128 threshold0 = uint128(bound(p.bpParams.threshold0, 2, type(uint128).max));
        uint128 threshold1 = uint128(bound(p.bpParams.threshold1, 1, threshold0 - 1));

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](3);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: rate0});
        bp[1] = LiquidityAllocationBracket({lowerThreshold: threshold0, rate: rate1});
        bp[2] = LiquidityAllocationBracket({lowerThreshold: threshold1, rate: rate2});

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidBracketThreshold.selector, threshold1));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    modifier whenBracketScheduleIsValid() {
        _;
    }

    function test_WhenTooManyBrackets(uint24 _rate3, uint128 _threshold2, MigrationFuzzParams memory p) public {
        uint24 rate0 = uint24(bound(p.bpParams.rate0, 1, MigratorParams.MAX_BRACKET_RATE));
        uint24 rate1 = uint24(bound(p.bpParams.rate1, 1, MigratorParams.MAX_BRACKET_RATE));
        uint24 rate2 = uint24(bound(p.bpParams.rate2, 1, MigratorParams.MAX_BRACKET_RATE));
        uint24 rate3 = uint24(bound(_rate3, 1, MigratorParams.MAX_BRACKET_RATE));
        uint128 threshold0 = uint128(bound(p.bpParams.threshold0, 1, type(uint128).max - 2));
        uint128 threshold1 = uint128(bound(p.bpParams.threshold1, threshold0 + 1, type(uint128).max - 1));
        uint128 threshold2 = uint128(bound(_threshold2, threshold1 + 1, type(uint128).max));

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](4);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: rate0});
        bp[1] = LiquidityAllocationBracket({lowerThreshold: threshold0, rate: rate1});
        bp[2] = LiquidityAllocationBracket({lowerThreshold: threshold1, rate: rate2});
        bp[3] = LiquidityAllocationBracket({lowerThreshold: threshold2, rate: rate3});

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidBracketCount.selector, 4));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenBracketLowerThresholdsAreEqual(
        uint24 _rate0,
        uint24 _rate1,
        uint24 _rate2,
        uint128 _threshold,
        MigrationFuzzParams memory p
    ) public {
        _rate0 = uint24(bound(_rate0, 1, MigratorParams.MAX_BRACKET_RATE));
        _rate1 = uint24(bound(_rate1, 1, MigratorParams.MAX_BRACKET_RATE));
        _rate2 = uint24(bound(_rate2, 1, MigratorParams.MAX_BRACKET_RATE));
        _threshold = uint128(bound(_threshold, 1, type(uint128).max));

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](3);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: _rate0});
        bp[1] = LiquidityAllocationBracket({lowerThreshold: _threshold, rate: _rate1});
        bp[2] = LiquidityAllocationBracket({lowerThreshold: _threshold, rate: _rate2});

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidBracketThreshold.selector, _threshold));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, bp, hex""), bytes32(0));
    }

    function test_WhenBracketRateExactlyAtMaxBracketRate(MigrationFuzzParams memory p) public {
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        LiquidityAllocationBracket[] memory bp = new LiquidityAllocationBracket[](1);
        bp[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});

        bytes memory initializerParams = _encodeMockInitializerParams(
            endBlock, address(0), LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0})
        );
        // Should not revert — rate is exactly MAX_BRACKET_RATE
        strategy.initializeDistribution(
            address(token), totalSupply, _encodeConfigData(mp, bp, initializerParams), bytes32(0)
        );
    }

    function test_WhenTickSpacingIsOutOfBounds(int24 _tickSpacing, MigrationFuzzParams memory p)
        public
        whenBracketScheduleIsValid
    {
        // it reverts with {InvalidTickSpacing}
        vm.assume(_tickSpacing > TickMath.MAX_TICK_SPACING || _tickSpacing < TickMath.MIN_TICK_SPACING);

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        mp.poolTickSpacing = _tickSpacing;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategy.InvalidTickSpacing.selector,
                _tickSpacing,
                TickMath.MIN_TICK_SPACING,
                TickMath.MAX_TICK_SPACING
            )
        );
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    modifier whenTickSpacingIsValid() {
        _;
    }

    function test_WhenFeeIsAboveMax(uint24 _fee, MigrationFuzzParams memory p)
        public
        whenBracketScheduleIsValid
        whenTickSpacingIsValid
    {
        // it reverts with {InvalidFee}
        _fee = uint24(bound(_fee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));
        if (_fee == LPFeeLibrary.DYNAMIC_FEE_FLAG) _fee++;

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        mp.poolLPFee = _fee;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidFee.selector, _fee, LPFeeLibrary.MAX_LP_FEE));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    function test_WhenFeeIsDynamicFeeFlag(MigrationFuzzParams memory p)
        public
        whenBracketScheduleIsValid
        whenTickSpacingIsValid
    {
        // it stores the migration parameters
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);
        mp.poolLPFee = LPFeeLibrary.DYNAMIC_FEE_FLAG;

        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, _boundBrackets(p.bpParams));

        (MigratorParameters memory storedParams) = strategy.initializers(ILBPInitializer(address(initializer)));
        assertEq(storedParams.poolLPFee, LPFeeLibrary.DYNAMIC_FEE_FLAG);
    }

    modifier whenFeeIsValid() {
        _;
    }

    function test_WhenPositionRecipientIsReserved(uint256 _seed, MigrationFuzzParams memory p)
        public
        whenBracketScheduleIsValid
        whenTickSpacingIsValid
        whenFeeIsValid
    {
        // it reverts with {InvalidPositionRecipient}
        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        if (_seed % 3 == 0) {
            mp.lpPositionRecipient = address(0);
        } else if (_seed % 3 == 1) {
            mp.lpPositionRecipient = ActionConstants.MSG_SENDER;
        } else {
            mp.lpPositionRecipient = ActionConstants.ADDRESS_THIS;
        }

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidPositionRecipient.selector, mp.lpPositionRecipient));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    modifier whenPositionRecipientIsValid() {
        _;
    }

    function test_WhenSupplyForLpExceedsInt128Max(uint128 _supplyForLP, MigrationFuzzParams memory p)
        public
        whenBracketScheduleIsValid
        whenTickSpacingIsValid
        whenFeeIsValid
        whenPositionRecipientIsValid
    {
        // it reverts with {InvalidSupplyForLp}
        _supplyForLP = uint128(bound(_supplyForLP, uint128(type(int128).max) + 1, type(uint128).max));

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        mp.supplyForLP = _supplyForLP;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.InvalidSupplyForLp.selector, _supplyForLP, uint128(type(int128).max))
        );
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    modifier whenSupplyForLpIsValid() {
        _;
    }

    function test_WhenPositionDefinitionsIsEmpty(MigrationFuzzParams memory p)
        public
        whenBracketScheduleIsValid
        whenTickSpacingIsValid
        whenFeeIsValid
        whenPositionRecipientIsValid
        whenSupplyForLpIsValid
    {
        // it reverts with {EmptyPositionPlan}
        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        mp.positionDefinitions = abi.encode(new PositionDefinition[](0));

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(PositionPlanner.EmptyPositionPlan.selector);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    function test_WhenAllocationWeightsDontSumToMPS(uint24 _weight, MigrationFuzzParams memory p)
        public
        whenBracketScheduleIsValid
        whenTickSpacingIsValid
        whenFeeIsValid
        whenPositionRecipientIsValid
        whenSupplyForLpIsValid
    {
        // it reverts with {InvalidAllocationWeights}
        _weight = uint24(bound(_weight, 0, type(uint24).max));
        vm.assume(_weight != 1e7);

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: _weight});
        mp.positionDefinitions = abi.encode(defs);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.InvalidAllocationWeights.selector, _weight));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    function test_WhenPositionDefinitionTickBoundsAreInvalid(
        int24 _offsetLower,
        int24 _offsetUpper,
        MigrationFuzzParams memory p
    )
        public
        whenBracketScheduleIsValid
        whenTickSpacingIsValid
        whenFeeIsValid
        whenPositionRecipientIsValid
        whenSupplyForLpIsValid
    {
        // it reverts with {InvalidTickBounds}
        _offsetLower = int24(bound(_offsetLower, TickMath.MIN_TICK, TickMath.MAX_TICK));
        _offsetUpper = int24(bound(_offsetUpper, TickMath.MIN_TICK, _offsetLower));

        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: _offsetLower, offsetUpper: _offsetUpper, weight: 1e7});
        mp.positionDefinitions = abi.encode(defs);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.InvalidTickBounds.selector, _offsetLower, _offsetUpper));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    function test_WhenPositionDefinitionCountExceedsMax(MigrationFuzzParams memory p)
        public
        whenBracketScheduleIsValid
        whenTickSpacingIsValid
        whenFeeIsValid
        whenPositionRecipientIsValid
        whenSupplyForLpIsValid
    {
        // it reverts with {TooManyPositions}
        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        PositionDefinition[] memory defs = new PositionDefinition[](PositionPlanner.MAX_POSITIONS_PER_PLAN + 1);
        for (uint256 i; i < defs.length; i++) {
            uint24 weight = i == defs.length - 1 ? uint24(1e7 - PositionPlanner.MAX_POSITIONS_PER_PLAN) : uint24(1);
            defs[i] = PositionDefinition({offsetLower: -100, offsetUpper: 100, weight: weight});
        }
        mp.positionDefinitions = abi.encode(defs);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(
            abi.encodeWithSelector(
                PositionPlanner.TooManyPositions.selector,
                PositionPlanner.MAX_POSITIONS_PER_PLAN + 1,
                PositionPlanner.MAX_POSITIONS_PER_PLAN
            )
        );
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
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

        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        uint128 expectedAuctionSupply = totalSupply - mp.supplyForLP;
        MockLBPInitializer badInit = new MockLBPInitializer(
            address(1), address(0), expectedAuctionSupply, address(strategy), _wrongRecipient, 0, endBlock
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidRecipient.selector, address(strategy)));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
    }

    function test_WhenInitializerEndBlockGTEMigrationBlock(uint64 _endBlockOffset, MigrationFuzzParams memory p)
        public
        whenMigratorParamsAreValid
    {
        // it reverts with {InvalidEndBlock}
        (MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);

        // endBlock >= migrationBlock
        uint64 endBlock = uint64(bound(_endBlockOffset, mp.migrationBlock, type(uint64).max));

        uint128 expectedAuctionSupply = totalSupply - mp.supplyForLP;
        MockLBPInitializer badInit = new MockLBPInitializer(
            address(1), address(0), expectedAuctionSupply, address(strategy), address(strategy), 0, endBlock
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));
        bytes memory configData = _encodeConfigData(mp, _boundBrackets(p.bpParams), hex"");

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidEndBlock.selector, endBlock, mp.migrationBlock));
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(0));
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
        (MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock, _boundBrackets(p.bpParams));

        assertNotEq(address(initializer), address(0));

        // Verify migration parameters were stored correctly
        (MigratorParameters memory storedParams) = strategy.initializers(ILBPInitializer(address(initializer)));
        assertEq(storedParams.migrationBlock, mp.migrationBlock);
        assertEq(storedParams.poolLPFee, mp.poolLPFee);
        assertEq(storedParams.poolTickSpacing, mp.poolTickSpacing);
        assertEq(storedParams.supplyForLP, mp.supplyForLP);
        assertEq(storedParams.fundsRecipient, mp.fundsRecipient);
        assertEq(storedParams.lpPositionRecipient, mp.lpPositionRecipient);
        assertEq(storedParams.hook, mp.hook);
        assertEq(storedParams.positionDefinitions, mp.positionDefinitions);
        assertEq(storedParams.lpAllocationSchedule, abi.encode(_boundBrackets(p.bpParams)));
    }
}
