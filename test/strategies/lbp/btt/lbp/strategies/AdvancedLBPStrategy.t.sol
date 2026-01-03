// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/strategies/lbp/AdvancedLBPStrategy.sol";
import {BttTests} from "../definitions/BttTests.sol";
import {BttBase, FuzzConstructorParameters} from "../BttBase.sol";
import {ILBPStrategyTestExtension} from "./ILBPStrategyTestExtension.sol";
import {Plan} from "src/libraries/StrategyPlanner.sol";
import {ActionsBuilder} from "src/libraries/ActionsBuilder.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";

contract AdvancedLBPStrategyTestExtension is AdvancedLBPStrategy, ILBPStrategyTestExtension {
    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        bool _createOneSidedTokenPosition,
        bool _createOneSidedCurrencyPosition
    )
        AdvancedLBPStrategy(
            _token,
            _totalSupply,
            _migratorParams,
            _auctionParams,
            _positionManager,
            _poolManager,
            _createOneSidedTokenPosition,
            _createOneSidedCurrencyPosition
        )
    {}

    function prepareMigrationData() external returns (MigrationData memory) {
        return _prepareMigrationData();
    }

    function createPositionPlan(MigrationData memory data) external returns (bytes memory) {
        return _createPositionPlan(data);
    }

    function getTokenTransferAmount(MigrationData memory data) external view returns (uint128) {
        return _getTokenTransferAmount(data);
    }

    function getCurrencyTransferAmount(MigrationData memory data) external view returns (uint128) {
        return _getCurrencyTransferAmount(data);
    }
}

/// @title AdvancedLBPStrategyTest
/// @notice Contract for testing the AdvancedLBPStrategy contract
contract AdvancedLBPStrategyTest is BttTests {
    using ActionsBuilder for bytes;

    bool public createOneSidedTokenPosition;
    bool public createOneSidedCurrencyPosition;

    constructor() {
        // Default to true
        createOneSidedTokenPosition = true;
        createOneSidedCurrencyPosition = true;
    }

    /// @dev Modifier to set createOneSidedTokenPosition to false for the duration of the test
    modifier givenCreateOneSidedTokenPositionIsFalse() {
        createOneSidedTokenPosition = false;
        _;
        createOneSidedTokenPosition = true;
    }

    /// @dev Modifier to set createOneSidedCurrencyPosition to false for the duration of the test
    modifier givenCreateOneSidedCurrencyPositionIsFalse() {
        createOneSidedCurrencyPosition = false;
        _;
        createOneSidedCurrencyPosition = true;
    }

    /// @inheritdoc BttBase
    function _contractName() internal pure override returns (string memory) {
        return "AdvancedLBPStrategyTestExtension";
    }

    /// @inheritdoc BttBase
    function _encodeConstructorArgs(FuzzConstructorParameters memory _parameters)
        internal
        override
        returns (bytes memory)
    {
        return abi.encode(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.initializerParameters,
            _parameters.positionManager,
            _parameters.poolManager,
            createOneSidedTokenPosition,
            createOneSidedCurrencyPosition
        );
    }

    function test_createPositionPlan_WhenCreateOneSidedTokenPositionAndCreateOneSidedCurrencyPositionAreFalse(
        FuzzConstructorParameters memory _parameters,
        uint128 _currencyAmount,
        bool _useNativeCurrency
    ) public givenCreateOneSidedTokenPositionIsFalse givenCreateOneSidedCurrencyPositionIsFalse {
        // it creates a full range position
        // it adds a take pair action and params

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);
        assertFalse(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedTokenPosition());
        assertFalse(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedCurrencyPosition());

        AuctionParameters memory initializerParameters =
            abi.decode(_parameters.initializerParameters, (AuctionParameters));

        mockCurrencyRaised(lbp, _currencyAmount);
        mockAuctionClearingPrice(lbp, initializerParameters.floorPrice);

        MigrationData memory data = ILBPStrategyTestExtension(address(lbp)).prepareMigrationData();
        bytes memory encodedPlan = ILBPStrategyTestExtension(address(lbp)).createPositionPlan(data);

        (bytes memory actions, bytes[] memory params) = abi.decode(encodedPlan, (bytes, bytes[]));
        assertEq(actions.length, 3 + 1);
        assertEq(actions, ActionsBuilder.init().addMint().addSettle().addSettle().addTakePair());
        assertEq(params.length, 3 + 1);
    }

    modifier givenCreateOneSidedTokenPositionIsTrue() {
        _;
    }

    function test_createPositionPlan_WhenCreateOneSidedTokenPositionIsTrueAndReserveSupplyIsGTThanInitialTokenAmount(
        FuzzConstructorParameters memory _parameters,
        uint128 _currencyAmount,
        bool _useNativeCurrency
    ) public givenCreateOneSidedCurrencyPositionIsFalse {
        // it does not create a one sided token position

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);
        assertTrue(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedTokenPosition());
        assertFalse(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedCurrencyPosition());

        AuctionParameters memory initializerParameters =
            abi.decode(_parameters.initializerParameters, (AuctionParameters));

        mockCurrencyRaised(lbp, _currencyAmount);
        mockAuctionClearingPrice(lbp, initializerParameters.floorPrice);

        MigrationData memory data = ILBPStrategyTestExtension(address(lbp)).prepareMigrationData();

        vm.assume(lbp.reserveSupply() <= data.initialTokenAmount);

        bytes memory encodedPlan = ILBPStrategyTestExtension(address(lbp)).createPositionPlan(data);

        (bytes memory actions, bytes[] memory params) = abi.decode(encodedPlan, (bytes, bytes[]));
        assertEq(actions.length, 3 + 1); // mint + settle + settle + take pair
        assertEq(actions, ActionsBuilder.init().addMint().addSettle().addSettle().addTakePair());
        assertEq(params.length, 3 + 1); // mint + settle + settle + take pair
    }

    modifier givenReserveSupplyIsGTThanInitialTokenAmount() {
        _;
    }

    function test_createPositionPlan_WhenCreateOneSidedTokenPositionIsTrueAndReserveSupplyIsLTEThanInitialTokenAmount(
        FuzzConstructorParameters memory _parameters,
        uint128 _currencyAmount,
        bool _useNativeCurrency
    ) public givenCreateOneSidedCurrencyPositionIsFalse givenReserveSupplyIsGTThanInitialTokenAmount {
        // it creates a full range position
        // it creates a one sided token position
        // it adds a take pair action and params

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);
        assertTrue(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedTokenPosition());
        assertFalse(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedCurrencyPosition());

        AuctionParameters memory initializerParameters =
            abi.decode(_parameters.initializerParameters, (AuctionParameters));

        mockCurrencyRaised(lbp, _currencyAmount);
        mockAuctionClearingPrice(lbp, initializerParameters.floorPrice);

        MigrationData memory data = ILBPStrategyTestExtension(address(lbp)).prepareMigrationData();

        vm.assume(lbp.reserveSupply() > data.initialTokenAmount);

        bytes memory encodedPlan = ILBPStrategyTestExtension(address(lbp)).createPositionPlan(data);

        (bytes memory actions, bytes[] memory params) = abi.decode(encodedPlan, (bytes, bytes[]));
        assertEq(actions.length, 3 + 1 + 1); // mint + settle + settle + mint + take pair
        assertEq(actions, ActionsBuilder.init().addMint().addSettle().addSettle().addMint().addTakePair());
        assertEq(params.length, 3 + 1 + 1); // mint + settle + settle + mint + take pair
    }

    modifier givenReserveSupplyIsLTEThanInitialTokenAmount() {
        _;
    }

    function test_createPositionPlan_WhenCreateOneSidedCurrencyPositionIsTrueAndLeftoverCurrencyIsEqualTo0(
        FuzzConstructorParameters memory _parameters,
        uint128 _currencyAmount,
        bool _useNativeCurrency
    ) public givenCreateOneSidedTokenPositionIsFalse {
        // it creates a full range position
        // it does not create a one sided currency position

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);
        assertFalse(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedTokenPosition());
        assertTrue(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedCurrencyPosition());

        AuctionParameters memory initializerParameters =
            abi.decode(_parameters.initializerParameters, (AuctionParameters));

        mockCurrencyRaised(lbp, _currencyAmount);
        mockAuctionClearingPrice(lbp, initializerParameters.floorPrice);

        MigrationData memory data = ILBPStrategyTestExtension(address(lbp)).prepareMigrationData();
        vm.assume(data.leftoverCurrency == 0);

        bytes memory encodedPlan = ILBPStrategyTestExtension(address(lbp)).createPositionPlan(data);
        (bytes memory actions, bytes[] memory params) = abi.decode(encodedPlan, (bytes, bytes[]));
        assertEq(actions.length, 3 + 1);
        assertEq(actions, ActionsBuilder.init().addMint().addSettle().addSettle().addTakePair());
        assertEq(params.length, 3 + 1);
    }

    modifier givenLeftoverCurrencyIsGTThan0() {
        _;
    }

    function test_createPositionPlan_WhenCreateOneSidedCurrencyPositionIsTrueAndLeftoverCurrencyIsGTThan0(
        FuzzConstructorParameters memory _parameters,
        uint128 _currencyAmount,
        bool _useNativeCurrency
    ) public givenCreateOneSidedTokenPositionIsFalse givenLeftoverCurrencyIsGTThan0 {
        // it creates a full range position
        // it creates a one sided currency position
        // it adds a take pair action and params

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);
        assertFalse(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedTokenPosition());
        assertTrue(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedCurrencyPosition());

        AuctionParameters memory initializerParameters =
            abi.decode(_parameters.initializerParameters, (AuctionParameters));

        // Large currency amounts can trip safe cast overflows in the V4 LiquidityAmounts library
        _currencyAmount = uint128(_bound(_currencyAmount, 1, 1e30));
        mockCurrencyRaised(lbp, _currencyAmount);
        mockAuctionClearingPrice(lbp, initializerParameters.floorPrice);

        MigrationData memory data = ILBPStrategyTestExtension(address(lbp)).prepareMigrationData();
        vm.assume(data.leftoverCurrency > 0);

        bytes memory encodedPlan = ILBPStrategyTestExtension(address(lbp)).createPositionPlan(data);
        (bytes memory actions, bytes[] memory params) = abi.decode(encodedPlan, (bytes, bytes[]));
        assertEq(actions.length, 3 + 1 + 1);
        assertEq(actions, ActionsBuilder.init().addMint().addSettle().addSettle().addMint().addTakePair());
        assertEq(params.length, 3 + 1 + 1);
    }

    modifier givenCreateOneSidedCurrencyPositionIsTrue() {
        _;
    }

    // TODO(eric): Fix this test which rejects too many inputs
    function xtest_createPositionPlan_WhenCreateOneSidedTokenPositionIsTrueAndCreateOneSidedCurrencyPositionIsTrue(
        FuzzConstructorParameters memory _parameters,
        uint128 _currencyAmount,
        bool _useNativeCurrency
    ) public givenCreateOneSidedTokenPositionIsTrue givenCreateOneSidedCurrencyPositionIsTrue {
        // it creates a full range position
        // it creates a one sided token position
        // it creates a one sided currency position
        // it adds a take pair action and params

        _parameters = _toValidConstructorParameters(_parameters, _useNativeCurrency);
        // Send half the tokens to the auction
        _parameters.migratorParams.tokenSplit = uint24(1e7 / 2);

        AuctionParameters memory initializerParameters =
            abi.decode(_parameters.initializerParameters, (AuctionParameters));
        _currencyAmount = uint128(_parameters.totalSupply * initializerParameters.floorPrice) >> 96;
        vm.assume(_currencyAmount > 2);

        // Set max currency amount to at most the currency amount
        _parameters.migratorParams.maxCurrencyAmountForLP =
            uint128(_bound(_parameters.migratorParams.maxCurrencyAmountForLP, 1, _currencyAmount - 1));

        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        _deployStrategy(_parameters);
        assertTrue(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedTokenPosition());
        assertTrue(AdvancedLBPStrategy(payable(address(lbp))).createOneSidedCurrencyPosition());

        mockCurrencyRaised(lbp, _currencyAmount);
        mockAuctionClearingPrice(lbp, initializerParameters.floorPrice + initializerParameters.tickSpacing);

        MigrationData memory data = ILBPStrategyTestExtension(address(lbp)).prepareMigrationData();
        vm.assume(lbp.reserveSupply() > data.initialTokenAmount);
        vm.assume(data.leftoverCurrency > 0);

        bytes memory encodedPlan = ILBPStrategyTestExtension(address(lbp)).createPositionPlan(data);
        (bytes memory actions, bytes[] memory params) = abi.decode(encodedPlan, (bytes, bytes[]));
        assertEq(actions.length, 3 + 1 + 1 + 1);
        assertEq(actions, ActionsBuilder.init().addMint().addSettle().addSettle().addMint().addMint().addTakePair());
        assertEq(params.length, 3 + 1 + 1 + 1);
    }
}
