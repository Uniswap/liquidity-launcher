// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttTests} from "../definitions/BttTests.sol";
import {BttBase, FuzzConstructorParameters} from "../BttBase.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {VirtualGovernedLBPStrategy} from "src/strategies/lbp/VirtualGovernedLBPStrategy.sol";
import {ILBPStrategyTestExtension} from "./ILBPStrategyTestExtension.sol";
import {MigratorParameters} from "src/types/MigratorParameters.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MigrationData} from "src/types/MigrationData.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockVirtualERC20} from "test/mocks/MockVirtualERC20.sol";

contract VirtualGovernedLBPStrategyTestExtension is VirtualGovernedLBPStrategy, ILBPStrategyTestExtension {
    using CurrencyLibrary for Currency;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        address _governance
    )
        VirtualGovernedLBPStrategy(
            _token, _totalSupply, _migratorParams, _auctionParams, _positionManager, _poolManager, _governance
        )
    {}

    function prepareMigrationData() external view returns (MigrationData memory) {
        return _prepareMigrationData();
    }

    function createPositionPlan(MigrationData memory data) external returns (bytes memory) {
        return _createPositionPlan(data);
    }

    function getTokenTransferAmount(MigrationData memory data) external pure returns (uint128) {
        return _getTokenTransferAmount(data);
    }

    function getCurrencyTransferAmount(MigrationData memory data) external pure returns (uint128) {
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

/// @title VirtualGovernedLBPStrategyTest
/// @notice Contract for testing the VirtualGovernedLBPStrategy contract
contract VirtualGovernedLBPStrategyTest is BttTests {
    // TODO: dummy governance address
    address governance = makeAddr("governance");

    /// @inheritdoc BttBase
    function _contractName() internal pure override returns (string memory) {
        return "VirtualGovernedLBPStrategyTestExtension";
    }

    /// @inheritdoc BttBase
    function _getHookAddress() internal pure override returns (address) {
        return address(
            uint160(
                uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_FLAG
            )
        );
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
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager,
            governance
        );
    }

    function test_transferAssetsAndExecutePlan_WhenCurrencyIsNative(
        FuzzConstructorParameters memory _parameters,
        uint128 _tokenAmount,
        uint128 _currencyAmount
    ) public {
        // it transfers token to the position manager
        // it calls modifyLiquidities with the plan with non zero value and the current block timestamp

        _parameters = _toValidConstructorParameters(_parameters, true);
        _parameters.token = MOCK_VIRTUAL_TOKEN;
        _deployMockVirtualToken(_parameters.totalSupply);

        _deployStrategy(_parameters);
        // Fully collateralize the mock virtual token
        deal(UNDERLYING_TOKEN, MOCK_VIRTUAL_TOKEN, _parameters.totalSupply);
        // Deal to the lbp
        deal(address(MOCK_VIRTUAL_TOKEN), address(lbp), _parameters.totalSupply);
        _tokenAmount = uint128(_bound(_tokenAmount, 1, _parameters.totalSupply));

        bytes memory mockPlan = bytes("");

        address positionManager = address(VirtualGovernedLBPStrategy(payable(address(lbp))).positionManager());

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
    ) public {
        // it transfers token to the position manager
        // it transfers currency to the position manager
        // it calls modifyLiquidities with the plan with zero value and the current block timestamp

        _parameters = _toValidConstructorParameters(_parameters, false);
        _parameters.token = MOCK_VIRTUAL_TOKEN;
        _deployMockVirtualToken(_parameters.totalSupply);
        _deployMockCurrency(_parameters.totalSupply);

        address currency = _parameters.migratorParams.currency;

        _deployStrategy(_parameters);
        // Fully collateralize the mock virtual token
        deal(UNDERLYING_TOKEN, MOCK_VIRTUAL_TOKEN, _parameters.totalSupply);
        // Deal to the lbp
        deal(address(MOCK_VIRTUAL_TOKEN), address(lbp), _parameters.totalSupply);
        deal(currency, address(lbp), _parameters.totalSupply);
        _tokenAmount = uint128(_bound(_tokenAmount, 1, _parameters.totalSupply));
        _currencyAmount = uint128(_bound(_currencyAmount, 1, _parameters.totalSupply));

        bytes memory mockPlan = bytes("");

        address positionManager = address(VirtualGovernedLBPStrategy(payable(address(lbp))).positionManager());

        address poolToken = ILBPStrategyTestExtension(address(lbp)).getPoolToken();

        uint256 posmTokenBalanceBefore = Currency.wrap(poolToken).balanceOf(positionManager);
        uint256 posmCurrencyBalanceBefore =
            Currency.wrap(_parameters.migratorParams.currency).balanceOf(positionManager);

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
        assertEq(
            Currency.wrap(_parameters.migratorParams.currency).balanceOf(positionManager),
            posmCurrencyBalanceBefore + _currencyAmount
        );
    }
}
