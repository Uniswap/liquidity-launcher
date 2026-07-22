// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BuybackAndBurnPositionRecipient} from "../../src/periphery/BuybackAndBurnPositionRecipient.sol";
import {ILPFeesPositionRecipient} from "../../src/interfaces/ILPFeesPositionRecipient.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TimelockedPositionRecipientTest} from "./TimelockedPositionRecipient.t.sol";
import {MockLPFeesExecutor} from "./MockLPFeesExecutor.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";

contract BuybackAndBurnPositionRecipientTest is TimelockedPositionRecipientTest {
    using CurrencyLibrary for Currency;

    BuybackAndBurnPositionRecipient internal positionRecipient;
    MockLPFeesExecutor internal executor;

    MockERC20 token;
    MockERC20 currency;

    function setUp() public virtual override {
        // Setups up fork and operator/searcher
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        token = new MockERC20("Test Token", "TEST", 1_000e18, address(this));
        currency = new MockERC20("Test Currency", "TESTC", 1_000e18, address(this));
        executor = new MockLPFeesExecutor();
    }

    // Return a basic BuybackAndBurnPositionRecipient for compatibility with TimelockedPositionRecipientTest
    function _getPositionRecipient(uint64 _timelockBlockNumber)
        internal
        virtual
        override
        returns (ITimelockedPositionRecipient)
    {
        return new BuybackAndBurnPositionRecipient(
            address(token),
            address(currency),
            operator,
            IPositionManager(POSITION_MANAGER),
            _timelockBlockNumber,
            1 // nonzero min token burn amount, exact value doesn't matter for these tests
        );
    }

    function test_CanBeConstructed(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount) public {
        vm.assume(_minTokenBurnAmount > 0);
        positionRecipient = new BuybackAndBurnPositionRecipient(
            address(token),
            address(currency),
            operator,
            IPositionManager(POSITION_MANAGER),
            _timelockBlockNumber,
            _minTokenBurnAmount
        );

        assertEq(positionRecipient.timelockBlockNumber(), _timelockBlockNumber);
        assertEq(positionRecipient.minTokenBurnAmount(), _minTokenBurnAmount);
        assertEq(positionRecipient.token(), address(token));
        assertEq(positionRecipient.currency(), address(currency));
        assertEq(positionRecipient.operator(), operator);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
    }

    function test_RevertsIfTokenIsZeroAddress(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount) public {
        vm.expectRevert(BuybackAndBurnPositionRecipient.InvalidToken.selector);
        new BuybackAndBurnPositionRecipient(
            address(0),
            address(currency),
            operator,
            IPositionManager(POSITION_MANAGER),
            _timelockBlockNumber,
            _minTokenBurnAmount
        );
    }

    function test_RevertsIfTokenAndCurrencyAreTheSame(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount)
        public
    {
        vm.expectRevert(BuybackAndBurnPositionRecipient.TokenAndCurrencyCannotBeTheSame.selector);
        new BuybackAndBurnPositionRecipient(
            address(token),
            address(token),
            operator,
            IPositionManager(POSITION_MANAGER),
            _timelockBlockNumber,
            _minTokenBurnAmount
        );
    }

    function test_RevertsIfMinTokenBurnAmountIsZero(uint256 _timelockBlockNumber) public {
        vm.expectRevert(BuybackAndBurnPositionRecipient.InvalidMinTokenBurnAmount.selector);
        new BuybackAndBurnPositionRecipient(
            address(token), address(currency), operator, IPositionManager(POSITION_MANAGER), _timelockBlockNumber, 0
        );
    }

    function test_onFeesReceived_recordsFeesWithoutPositionOwnership() public {
        positionRecipient =
            new BuybackAndBurnPositionRecipient(USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, 1);
        _notifyForkFees();

        (uint256 currency0Fees, uint256 currency1Fees) = positionRecipient.fees(FORK_TOKEN_ID);
        assertEq(currency0Fees, FORK_CURRENCY0_FEES_AMOUNT);
        assertEq(currency1Fees, 0);
    }

    function test_collectFees_revertsIfPositionIsInvalid() public {
        positionRecipient =
            new BuybackAndBurnPositionRecipient(USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, 1);

        vm.expectRevert(abi.encodeWithSelector(ILPFeesPositionRecipient.InvalidPosition.selector, type(uint256).max));
        positionRecipient.collectFees(type(uint256).max, 0, 0);
    }

    function test_collectFees_revertsIfPoolDoesNotMatchConfiguredPair() public {
        // Configured for MockERC20/NATIVE, but FORK_TOKEN_ID belongs to the NATIVE/USDC pool
        positionRecipient = new BuybackAndBurnPositionRecipient(
            address(token), NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, 1
        );
        _notifyForkFees();

        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackAndBurnPositionRecipient.InvalidPool.selector, Currency.wrap(NATIVE), Currency.wrap(USDC)
            )
        );
        executor.execute(positionRecipient, FORK_TOKEN_ID, 0, 0);
    }

    function test_collectFees_revertsIfMinimumBurnAmountIsNotMet(uint256 _minTokenBurnAmount) public {
        vm.assume(_minTokenBurnAmount > 0 && _minTokenBurnAmount < 1_000_000e6);

        positionRecipient = new BuybackAndBurnPositionRecipient(
            USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, _minTokenBurnAmount
        );

        executor.approveToken(USDC, address(positionRecipient), _minTokenBurnAmount - 1);
        _dealUSDCFromPoolManager(address(executor), _minTokenBurnAmount - 1);

        _notifyForkFees();

        vm.expectRevert(abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector));
        executor.execute(positionRecipient, FORK_TOKEN_ID, 0, 0);
    }

    function test_collectFees_revertsIfInsufficientCurrencyReceived(
        uint256 _minTokenBurnAmount,
        uint256 _minCurrencyAmount
    ) public {
        vm.assume(_minTokenBurnAmount > 0 && _minTokenBurnAmount < 1_000_000e6);
        _minCurrencyAmount = _bound(_minCurrencyAmount, FORK_CURRENCY0_FEES_AMOUNT + 1, type(uint256).max);

        positionRecipient = new BuybackAndBurnPositionRecipient(
            USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, _minTokenBurnAmount
        );
        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), _minTokenBurnAmount);

        _notifyForkFees();

        vm.expectRevert(
            abi.encodeWithSelector(
                ILPFeesPositionRecipient.InsufficientAmountReceived.selector,
                Currency.wrap(NATIVE),
                FORK_CURRENCY0_FEES_AMOUNT,
                _minCurrencyAmount
            )
        );
        executor.execute(positionRecipient, FORK_TOKEN_ID, _minCurrencyAmount, 0);
    }

    function test_collectFees_transfersCurrencyFeesToCaller(uint256 _minTokenBurnAmount, uint256 _minCurrencyAmount)
        public
    {
        vm.assume(_minTokenBurnAmount > 0 && _minTokenBurnAmount < 1_000_000e6);
        _minCurrencyAmount = _bound(_minCurrencyAmount, 0, FORK_CURRENCY0_FEES_AMOUNT);

        positionRecipient = new BuybackAndBurnPositionRecipient(
            USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, _minTokenBurnAmount
        );
        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), _minTokenBurnAmount);

        _notifyForkFees();

        uint256 deadAddressTokenBalanceBefore = Currency.wrap(USDC).balanceOf(address(0xdead));

        vm.expectEmit(true, true, true, true);
        emit BuybackAndBurnPositionRecipient.TokensBurned(_minTokenBurnAmount);
        uint256 executorCurrencyBalanceBefore = Currency.wrap(NATIVE).balanceOf(address(executor));

        vm.expectEmit(true, false, false, false, address(positionRecipient));
        emit ILPFeesPositionRecipient.FeesCollected(
            FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0, _poolKey(FORK_TOKEN_ID)
        );
        executor.execute(positionRecipient, FORK_TOKEN_ID, _minCurrencyAmount, 0);
        assertGt(
            Currency.wrap(NATIVE).balanceOf(address(executor)),
            executorCurrencyBalanceBefore,
            "Executor currency balance did not increase"
        );
        assertEq(
            Currency.wrap(USDC).balanceOf(address(positionRecipient)), 0, "Position recipient token balance is not 0"
        );
        assertEq(
            Currency.wrap(NATIVE).balanceOf(address(positionRecipient)),
            0,
            "Position recipient currency balance is not 0"
        );
        assertEq(
            Currency.wrap(USDC).balanceOf(address(0xdead)),
            deadAddressTokenBalanceBefore + _minTokenBurnAmount,
            "Dead address token balance did not increase by the minimum burn amount"
        );
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_collectFees_transfersCurrencyFeesToCaller_gas() public {
        uint256 minTokenBurnAmount = 1e6;
        uint256 minCurrencyAmount = 0;

        positionRecipient = new BuybackAndBurnPositionRecipient(
            USDC, NATIVE, operator, IPositionManager(POSITION_MANAGER), 0, minTokenBurnAmount
        );
        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), minTokenBurnAmount);

        _notifyForkFees();

        uint256 deadAddressTokenBalanceBefore = Currency.wrap(USDC).balanceOf(address(0xdead));
        uint256 executorCurrencyBalanceBefore = Currency.wrap(NATIVE).balanceOf(address(executor));

        executor.execute(positionRecipient, FORK_TOKEN_ID, minCurrencyAmount, 0);
        vm.snapshotGasLastCall("buybackAndBurn collectFees");

        assertGt(Currency.wrap(NATIVE).balanceOf(address(executor)), executorCurrencyBalanceBefore);
        assertEq(Currency.wrap(USDC).balanceOf(address(positionRecipient)), 0);
        assertEq(Currency.wrap(NATIVE).balanceOf(address(positionRecipient)), 0);
        assertEq(Currency.wrap(USDC).balanceOf(address(0xdead)), deadAddressTokenBalanceBefore + minTokenBurnAmount);
    }

    function _notifyForkFees() internal {
        vm.deal(address(positionRecipient), address(positionRecipient).balance + FORK_CURRENCY0_FEES_AMOUNT);
        positionRecipient.onFeesReceived(FORK_TOKEN_ID, Currency.wrap(NATIVE), FORK_CURRENCY0_FEES_AMOUNT);
    }
}
