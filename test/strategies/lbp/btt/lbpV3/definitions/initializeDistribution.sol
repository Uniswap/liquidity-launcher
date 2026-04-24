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
///     ├── when initializer.custody tokens mismatch
///     │   └── it reverts with InvalidCustodySupply
///     └── when initializer is valid
///         ├── it stores the migration parameters
///         └── it emits InitializerCreated
contract InitializeDistributionTest is LBPStrategyTestBase {
    function test_WhenCurrencySplitIsZero(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    ) public {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) =
            _boundMigratorParams(_endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, 1);
        mp.currencySplitForLP = 0;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCurrencySplitForLP.selector, 0, 0, 1e7));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenCurrencySplitIsOver100Percent(
        uint24 _split,
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    ) public {
        _split = uint24(bound(_split, 1e7 + 1, type(uint24).max));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) =
            _boundMigratorParams(_endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, 1);
        mp.currencySplitForLP = _split;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCurrencySplitForLP.selector, _split, 0, 1e7));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    function test_WhenCurrencySplitIsBelowMinimum(
        uint24 _minSplit,
        uint24 _split,
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP
    ) public {
        _minSplit = uint24(bound(_minSplit, 2, 10_000));
        _split = uint24(bound(_split, 1, _minSplit - 1));

        strategy.setMinSplitForLp(_minSplit);

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) =
            _boundMigratorParams(_endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, 1);
        mp.currencySplitForLP = _split;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidCurrencySplitForLP.selector, _split, _minSplit, 1e7));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenCurrencySplitIsValid() {
        _;
    }

    function test_WhenTickSpacingIsOutOfBounds(
        int24 _tickSpacing,
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public whenCurrencySplitIsValid {
        vm.assume(_tickSpacing > TickMath.MAX_TICK_SPACING || _tickSpacing < TickMath.MIN_TICK_SPACING);

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) =
            _boundMigratorParams(_endBlock, _migrationBlock, _poolLPFee, 1, _supplyForLP, _currencySplitForLP);
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

    function test_WhenFeeIsAboveMax(
        uint24 _fee,
        uint64 _endBlock,
        uint64 _migrationBlock,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public whenCurrencySplitIsValid whenTickSpacingIsValid {
        _fee = uint24(bound(_fee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) =
            _boundMigratorParams(_endBlock, _migrationBlock, 0, _poolTickSpacing, _supplyForLP, _currencySplitForLP);
        mp.poolLPFee = _fee;

        MockERC20 token = new MockERC20("Test Token", "TT", totalSupply, address(this));

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategy.InvalidFee.selector, _fee, LPFeeLibrary.MAX_LP_FEE));
        strategy.initializeDistribution(address(token), totalSupply, _encodeConfigData(mp, hex""), bytes32(0));
    }

    modifier whenFeeIsValid() {
        _;
    }

    function test_WhenPositionRecipientIsReserved(
        uint256 _seed,
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public whenCurrencySplitIsValid whenTickSpacingIsValid whenFeeIsValid {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(
            _endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );

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

    function test_WhenInitializerFundsRecipientIsWrong(
        address _wrongRecipient,
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public whenMigratorParamsAreValid {
        vm.assume(_wrongRecipient != address(strategy));

        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(
            _endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );

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

    function test_WhenInitializerEndBlockGTEMigrationBlock(
        uint64 _endBlockOffset,
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public whenMigratorParamsAreValid {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply,,) = _boundMigratorParams(
            _endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );

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

    function test_WhenInitializerCustodyTokensMismatch(
        uint128 _wrongCustody,
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public whenMigratorParamsAreValid {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(
            _endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );

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

    function test_WhenInitializerIsNew(
        uint64 _endBlock,
        uint64 _migrationBlock,
        uint24 _poolLPFee,
        int24 _poolTickSpacing,
        uint128 _supplyForLP,
        uint24 _currencySplitForLP
    ) public whenMigratorParamsAreValid whenInitializerIsValid {
        (ILBPStrategy.MigratorParameters memory mp, uint128 totalSupply, uint64 endBlock,) = _boundMigratorParams(
            _endBlock, _migrationBlock, _poolLPFee, _poolTickSpacing, _supplyForLP, _currencySplitForLP
        );

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
            address lpHook
        ) = strategy.initializers(ILBPInitializer(address(initializer)));

        assertEq(migrationBlock, mp.migrationBlock);
        assertEq(poolLPFee, mp.poolLPFee);
        assertEq(poolTickSpacing, mp.poolTickSpacing);
        assertEq(supplyForLP, mp.supplyForLP);
        assertEq(storedFundsRecipient, mp.fundsRecipient);
        assertEq(storedLpPositionRecipient, mp.lpPositionRecipient);
        assertEq(currencySplitForLP, mp.currencySplitForLP);
        assertEq(lpHook, mp.lpHook);
    }
}
