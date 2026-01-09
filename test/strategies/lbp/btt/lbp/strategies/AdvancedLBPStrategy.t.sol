// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "src/strategies/lbp/AdvancedLBPStrategy.sol";
import {BttTests} from "../definitions/BttTests.sol";
import {BttBase, FuzzConstructorParameters} from "../BttBase.sol";
import {ILBPStrategyTestExtension} from "./ILBPStrategyTestExtension.sol";
import {Plan} from "src/libraries/StrategyPlanner.sol";
import {ActionsBuilder} from "src/libraries/ActionsBuilder.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract AdvancedLBPStrategyTestExtension is AdvancedLBPStrategy, ILBPStrategyTestExtension {
    using CurrencyLibrary for Currency;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _initializerParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        bool _createOneSidedTokenPosition,
        bool _createOneSidedCurrencyPosition
    )
        AdvancedLBPStrategy(
            _token,
            _totalSupply,
            _migratorParams,
            _initializerParams,
            _positionManager,
            _poolManager,
            _createOneSidedTokenPosition,
            _createOneSidedCurrencyPosition
        )
    {}

    function prepareMigrationData() external view returns (MigrationData memory) {
        return _prepareMigrationData();
    }

    function createPositionPlan(MigrationData memory data) external view returns (bytes memory) {
        return _createPositionPlan(data);
    }

    function getTokenTransferAmount(MigrationData memory data) external view returns (uint128) {
        return _getTokenTransferAmount(data);
    }

    function getCurrencyTransferAmount(MigrationData memory data) external view returns (uint128) {
        return _getCurrencyTransferAmount(data);
    }

    function getPoolToken() external view returns (address) {
        return _getPoolToken();
    }

    function transferAssetsAndExecutePlan(
        uint128 tokenTransferAmount,
        uint128 currencyTransferAmount,
        bytes memory plan
    ) external {
        return _transferAssetsAndExecutePlan(tokenTransferAmount, currencyTransferAmount, plan);
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
        view
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

        mockLBPInitializationParams(
            lbp,
            LBPInitializationParams({
                initialPriceX96: initializerParameters.floorPrice, tokensSold: 0, currencyRaised: _currencyAmount
            })
        );

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

        mockLBPInitializationParams(
            lbp,
            LBPInitializationParams({
                initialPriceX96: initializerParameters.floorPrice, tokensSold: 0, currencyRaised: _currencyAmount
            })
        );

        MigrationData memory data = ILBPStrategyTestExtension(address(lbp)).prepareMigrationData();

        vm.assume(lbp.reserveTokenAmount() <= data.fullRangeTokenAmount);

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

        mockLBPInitializationParams(
            lbp,
            LBPInitializationParams({
                initialPriceX96: initializerParameters.floorPrice, tokensSold: 0, currencyRaised: _currencyAmount
            })
        );

        MigrationData memory data = ILBPStrategyTestExtension(address(lbp)).prepareMigrationData();

        vm.assume(lbp.reserveTokenAmount() > data.fullRangeTokenAmount);

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

        mockLBPInitializationParams(
            lbp,
            LBPInitializationParams({
                initialPriceX96: initializerParameters.floorPrice, tokensSold: 0, currencyRaised: _currencyAmount
            })
        );

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
        mockLBPInitializationParams(
            lbp,
            LBPInitializationParams({
                initialPriceX96: initializerParameters.floorPrice, tokensSold: 0, currencyRaised: _currencyAmount
            })
        );

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

        mockLBPInitializationParams(
            lbp,
            LBPInitializationParams({
                initialPriceX96: initializerParameters.floorPrice + initializerParameters.tickSpacing,
                tokensSold: 0,
                currencyRaised: _currencyAmount
            })
        );

        MigrationData memory data = ILBPStrategyTestExtension(address(lbp)).prepareMigrationData();
        vm.assume(lbp.reserveTokenAmount() > data.fullRangeTokenAmount);
        vm.assume(data.leftoverCurrency > 0);

        bytes memory encodedPlan = ILBPStrategyTestExtension(address(lbp)).createPositionPlan(data);
        (bytes memory actions, bytes[] memory params) = abi.decode(encodedPlan, (bytes, bytes[]));
        assertEq(actions.length, 3 + 1 + 1 + 1);
        assertEq(actions, ActionsBuilder.init().addMint().addSettle().addSettle().addMint().addMint().addTakePair());
        assertEq(params.length, 3 + 1 + 1 + 1);
    }

    function test_transferAssetsAndExecutePlan_WhenCurrencyIsNative(
        FuzzConstructorParameters memory _parameters,
        uint128 _tokenAmount,
        uint128 _currencyAmount
    ) public givenCreateOneSidedTokenPositionIsFalse givenCreateOneSidedCurrencyPositionIsFalse {
        // it transfers token to the position manager
        // it calls modifyLiquidities with the plan with non zero value and the current block timestamp

        _parameters = _toValidConstructorParameters(_parameters, true);
        _deployMockToken(_parameters.totalSupply);

        _deployStrategy(_parameters);
        deal(address(token), address(lbp), _parameters.totalSupply);
        _tokenAmount = uint128(_bound(_tokenAmount, 1, _parameters.totalSupply));

        bytes memory mockPlan = bytes("");

        address positionManager = address(AdvancedLBPStrategy(payable(address(lbp))).positionManager());

        address poolToken = ILBPStrategyTestExtension(address(lbp)).getPoolToken();

        uint256 posmTokenBalanceBefore = Currency.wrap(poolToken).balanceOf(positionManager);

        vm.mockCall(
            positionManager,
            _currencyAmount,
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mockPlan, block.timestamp),
            bytes("")
        );
        vm.expectCall(
            positionManager,
            _currencyAmount,
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mockPlan, block.timestamp)
        );
        ILBPStrategyTestExtension(address(lbp)).transferAssetsAndExecutePlan(_tokenAmount, _currencyAmount, mockPlan);

        assertEq(Currency.wrap(poolToken).balanceOf(positionManager), posmTokenBalanceBefore + _tokenAmount);
    }

    function test_transferAssetsAndExecutePlan_WhenCurrencyIsNotNative(
        FuzzConstructorParameters memory _parameters,
        uint128 _tokenAmount,
        uint128 _currencyAmount
    ) public givenCreateOneSidedTokenPositionIsFalse givenCreateOneSidedCurrencyPositionIsFalse {
        // it transfers token to the position manager
        // it transfers currency to the position manager
        // it calls modifyLiquidities with the plan with zero value and the current block timestamp

        _parameters = _toValidConstructorParameters(_parameters, false);
        _deployMockToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        address currency = _parameters.migratorParams.currency;

        _deployStrategy(_parameters);
        deal(address(token), address(lbp), _parameters.totalSupply);
        deal(address(currency), address(lbp), _parameters.totalSupply);
        _tokenAmount = uint128(_bound(_tokenAmount, 1, _parameters.totalSupply));
        _currencyAmount = uint128(_bound(_currencyAmount, 1, _parameters.totalSupply));

        bytes memory mockPlan = bytes("");

        address positionManager = address(AdvancedLBPStrategy(payable(address(lbp))).positionManager());
        address poolToken = ILBPStrategyTestExtension(address(lbp)).getPoolToken();

        uint256 posmTokenBalanceBefore = Currency.wrap(poolToken).balanceOf(positionManager);
        uint256 posmCurrencyBalanceBefore = Currency.wrap(currency).balanceOf(positionManager);

        vm.mockCall(
            positionManager,
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mockPlan, block.timestamp),
            bytes("")
        );
        vm.expectCall(
            positionManager,
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector, mockPlan, block.timestamp)
        );
        ILBPStrategyTestExtension(address(lbp)).transferAssetsAndExecutePlan(_tokenAmount, _currencyAmount, mockPlan);

        assertEq(Currency.wrap(poolToken).balanceOf(positionManager), posmTokenBalanceBefore + _tokenAmount);
        assertEq(Currency.wrap(currency).balanceOf(positionManager), posmCurrencyBalanceBefore + _currencyAmount);
    }
}
