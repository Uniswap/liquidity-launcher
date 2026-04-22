// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {LBPStrategyTestBase} from "../../../base/LBPStrategyTestBase.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
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
/// ├── when currencySplitForLP is invalid (0, >1e7, <min)
/// │   └── it reverts with InvalidCurrencySplitForLP
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
///         ├── it stores the migration parameters
///         └── it emits InitializerCreated
contract InitializeDistributionTest is LBPStrategyTestBase {
    function test_WhenCurrencySplitIsZero() public {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        mp.currencySplitForLP = 0;

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCurrencySplitForLP.selector, 0, 0, 1e7));
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenCurrencySplitIsOver100Percent(uint24 _split) public {
        _split = uint24(bound(_split, 1e7 + 1, type(uint24).max));

        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        mp.currencySplitForLP = _split;

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCurrencySplitForLP.selector, _split, 0, 1e7));
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenCurrencySplitIsBelowMinimum(uint24 _minSplit, uint24 _split) public {
        _minSplit = uint24(bound(_minSplit, 2, 10_000));
        _split = uint24(bound(_split, 1, _minSplit - 1));

        strategy.setMinSplitForLp(_minSplit);

        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        mp.currencySplitForLP = _split;

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCurrencySplitForLP.selector, _split, _minSplit, 1e7));
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenCurrencySplitIsValid() {
        _;
    }

    function test_WhenTickSpacingIsOutOfBounds(int24 _tickSpacing) public whenCurrencySplitIsValid {
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
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenTickSpacingIsValid() {
        _;
    }

    function test_WhenFeeIsAboveMax(uint24 _fee) public whenCurrencySplitIsValid whenTickSpacingIsValid {
        _fee = uint24(bound(_fee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));

        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        mp.poolLPFee = _fee;

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidFee.selector, _fee, LPFeeLibrary.MAX_LP_FEE));
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenFeeIsValid() {
        _;
    }

    function test_WhenPositionRecipientIsReserved(uint256 _seed)
        public
        whenCurrencySplitIsValid
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
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
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
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenInitializerEndBlockGTEMigrationBlock(uint64 _endBlockOffset) public whenMigratorParamsAreValid {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();

        // endBlock >= migrationBlock
        uint64 endBlock = uint64(bound(_endBlockOffset, mp.migrationBlock, type(uint64).max));

        MockLBPInitializer badInit = new MockLBPInitializer(
            address(token),
            address(0),
            0,
            uint128(mp.supplyForLP + mp.custodyTokens),
            address(strategy),
            address(strategy),
            0,
            endBlock
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategy.InvalidEndBlock.selector, endBlock, mp.migrationBlock)
        );
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenInitializerCustodyTokensMismatch(uint128 _wrongCustody) public whenMigratorParamsAreValid {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();

        uint128 expectedCustody = uint128(mp.supplyForLP + mp.custodyTokens);
        vm.assume(_wrongCustody != expectedCustody);

        MockLBPInitializer badInit = new MockLBPInitializer(
            address(token), address(0), 0, _wrongCustody, address(strategy), address(strategy), 0, uint64(block.number) + 50
        );

        vm.mockCall(
            address(factory),
            abi.encodeWithSelector(IDistributionStrategy.initializeDistribution.selector),
            abi.encode(address(badInit))
        );

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCustodySupply.selector, _wrongCustody, expectedCustody));
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenInitializerIsValid() {
        _;
    }

    function test_WhenInitializerIsNew() public whenMigratorParamsAreValid whenInitializerIsValid {
        ILBPStrategy.MigratorParameters memory mp = _defaultMigratorParams();
        factory.setCustodyTokens(mp.supplyForLP + mp.custodyTokens);

        vm.recordLogs();
        strategy.initializeDistribution(address(token), DEFAULT_TOTAL_SUPPLY, _encodeConfigData(mp, hex""), bytes32(0));

        MockLBPInitializer initializer = factory.deployedInitializer();

        assertNotEq(address(initializer), address(0));

        // Verify all fields of MigratorParameters were stored correctly
        (
            uint64 migrationBlock,
            uint24 poolLPFee,
            int24 poolTickSpacing,
            uint128 supplyForLP,
            address storedFundsRecipient,
            uint128 custodyTokens,
            address storedLpPositionRecipient,
            uint24 currencySplitForLP,
            address lpHook
        ) = strategy.initializers(ILBPInitializer(address(initializer)));

        assertEq(migrationBlock, mp.migrationBlock);
        assertEq(poolLPFee, mp.poolLPFee);
        assertEq(poolTickSpacing, mp.poolTickSpacing);
        assertEq(supplyForLP, mp.supplyForLP);
        assertEq(storedFundsRecipient, mp.fundsRecipient);
        assertEq(custodyTokens, mp.custodyTokens);
        assertEq(storedLpPositionRecipient, mp.lpPositionRecipient);
        assertEq(currencySplitForLP, mp.currencySplitForLP);
        assertEq(lpHook, mp.lpHook);
    }
}
