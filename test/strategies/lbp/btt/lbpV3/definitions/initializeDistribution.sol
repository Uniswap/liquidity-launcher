// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PositionPlanner} from "src/libraries/PositionPlanner.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";

/// @title InitializeDistributionTest
/// @notice BTT tests for LBPStrategy.initializeDistribution
///
/// initializeDistribution
/// ├── when currencySplitForLP is invalid (0, >1e7, <min)
/// │   └── it reverts with InvalidCurrencySplitForLP
/// ├── when tickSpacing is out of bounds
/// │   └── it reverts with InvalidTickSpacing
/// ├── when fee > MAX_LP_FEE
/// │   └── it reverts with InvalidFee
/// ├── when positionRecipient is reserved
/// │   └── it reverts with InvalidPositionRecipient
/// ├── when position definitions contain invalid tick bounds
/// │   └── it reverts with InvalidTickBounds
/// ├── when position definitions exceed the max position count
/// │   └── it reverts with TooManyPositions
/// └── when migrator params are valid
///     ├── when initializer.fundsRecipient != strategy
///     │   └── it reverts with InvalidRecipient
///     ├── when initializer.endBlock >= migrationBlock
///     │   └── it reverts with InvalidEndBlock
///     ├── when initializer.custody tokens mismatch
///     │   └── it reverts with InvalidCustodySupply
///     └── when initializer is valid
///         ├── it stores the migration parameters
///         └── it emits InitializerCreated
contract InitializeDistributionTest is LBPStrategyTestBase {
    function test_WhenCurrencySplitIsZero(FuzzParams memory p) public {
        // it reverts with {InvalidCurrencySplitForLP}
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        mp.currencySplitForLP = 0;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCurrencySplitForLP.selector, 0, 1, 1e7));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenCurrencySplitIsOver100Percent(uint24 _split, FuzzParams memory p) public {
        // it reverts with {InvalidCurrencySplitForLP}
        _split = uint24(bound(_split, 1e7 + 1, type(uint24).max));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        mp.currencySplitForLP = _split;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCurrencySplitForLP.selector, _split, 1, 1e7));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenCurrencySplitIsBelowMinimum(uint24 _minSplit, uint24 _split, FuzzParams memory p) public {
        // it reverts with {InvalidCurrencySplitForLP}
        _minSplit = uint24(bound(_minSplit, 2, strategy.MAX_SPLIT_FOR_LP()));
        _split = uint24(bound(_split, 1, _minSplit - 1));

        strategy.setMinSplitForLp(_minSplit);

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        mp.currencySplitForLP = _split;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCurrencySplitForLP.selector, _split, _minSplit, 1e7));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenCurrencySplitIsValid() {
        _;
    }

    function test_WhenTickSpacingIsOutOfBounds(int24 _tickSpacing, FuzzParams memory p)
        public
        whenCurrencySplitIsValid
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

    function test_WhenFeeIsAboveMax(uint24 _fee, FuzzParams memory p)
        public
        whenCurrencySplitIsValid
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

    function test_WhenPositionRecipientIsReserved(uint256 _seed, FuzzParams memory p)
        public
        whenCurrencySplitIsValid
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

    function test_WhenPositionDefinitionTickBoundsAreInvalid(
        int24 _offsetLower,
        int24 _offsetUpper,
        FuzzParams memory p
    ) public whenCurrencySplitIsValid whenTickSpacingIsValid whenFeeIsValid whenPositionRecipientIsValid {
        // it reverts with {InvalidTickBounds}
        _offsetLower = int24(bound(_offsetLower, TickMath.MIN_TICK, TickMath.MAX_TICK));
        _offsetUpper = int24(bound(_offsetUpper, TickMath.MIN_TICK, _offsetLower));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({offsetLower: _offsetLower, offsetUpper: _offsetUpper, weight: 1e7});
        mp.positionDefinitions = abi.encode(defs);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.InvalidTickBounds.selector, _offsetLower, _offsetUpper));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenPositionDefinitionCountExceedsMax(FuzzParams memory p)
        public
        whenCurrencySplitIsValid
        whenTickSpacingIsValid
        whenFeeIsValid
        whenPositionRecipientIsValid
    {
        // it reverts with {TooManyPositions}
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(p);
        PositionDefinition[] memory defs = new PositionDefinition[](11);
        for (uint256 i; i < defs.length; i++) {
            uint24 weight = i == defs.length - 1 ? uint24(1e7 - 10) : uint24(1);
            defs[i] = PositionDefinition({offsetLower: -100, offsetUpper: 100, weight: weight});
        }
        mp.positionDefinitions = abi.encode(defs);

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.TooManyPositions.selector, 11, 10));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenMigratorParamsAreValid() {
        _;
    }

    function test_WhenInitializerFundsRecipientIsWrong(address _wrongRecipient, FuzzParams memory p)
        public
        whenMigratorParamsAreValid
    {
        // it reverts with {InvalidRecipient}
        vm.assume(_wrongRecipient != address(strategy));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        MockLBPInitializer badInit = new MockLBPInitializer(
            address(1), // token placeholder
            address(0),
            0,
            mp.supplyForLP,
            address(strategy),
            _wrongRecipient,
            0,
            endBlock
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

    function test_WhenInitializerEndBlockGTEMigrationBlock(uint64 _endBlockOffset, FuzzParams memory p)
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

    function test_WhenInitializerCustodyTokensMismatch(uint128 _wrongCustody, FuzzParams memory p)
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

    function test_WhenInitializerIsNew(FuzzParams memory p) public whenMigratorParamsAreValid whenInitializerIsValid {
        // it saves the parameters to storage
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(p);

        (MockLBPInitializer initializer,) = _initializeWith(mp, totalSupply, endBlock);

        assertNotEq(address(initializer), address(0));

        // Verify all fields of MigratorParameters were stored correctly
        (
            uint64 migrationBlock,
            uint24 poolLPFee,
            int24 poolTickSpacing,
            uint128 supplyForLP,
            address storedFundsRecipient,
            address storedLpPositionRecipient,
            uint24 currencySplitForLP,
            address lpHook,
            bytes memory positionDefinitions
        ) = strategy.initializers(ILBPInitializer(address(initializer)));

        assertEq(migrationBlock, mp.migrationBlock);
        assertEq(poolLPFee, mp.poolLPFee);
        assertEq(poolTickSpacing, mp.poolTickSpacing);
        assertEq(supplyForLP, mp.supplyForLP);
        assertEq(storedFundsRecipient, mp.fundsRecipient);
        assertEq(storedLpPositionRecipient, mp.lpPositionRecipient);
        assertEq(currencySplitForLP, mp.currencySplitForLP);
        assertEq(lpHook, mp.lpHook);
        assertEq(positionDefinitions, mp.positionDefinitions);
    }
}
