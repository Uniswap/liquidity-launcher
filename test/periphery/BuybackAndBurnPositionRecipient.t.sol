// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILPFeesPositionRecipient} from "../../src/interfaces/ILPFeesPositionRecipient.sol";
import {BuybackAndBurnPositionRecipient} from "../../src/periphery/BuybackAndBurnPositionRecipient.sol";
import {ITimelockedPositionRecipient} from "../../src/interfaces/ITimelockedPositionRecipient.sol";
import {TimelockedPositionRecipientTest} from "./TimelockedPositionRecipient.t.sol";
import {MockLPFeesExecutor} from "./MockLPFeesExecutor.sol";

contract BuybackAndBurnPositionRecipientTest is TimelockedPositionRecipientTest {
    /// @dev An existing position at FORK_BLOCK whose currency0 is an ERC20, not native ETH
    uint256 internal constant NON_ETH_FORK_TOKEN_ID = 107193;
    address internal constant NON_ETH_FORK_CURRENCY0 = 0x18F52B3fb465118731d9e0d276d4Eb3599D57596;
    /// @dev An existing native ETH position at FORK_BLOCK in a different pool (ETH/UNI; UNI has
    ///      18 decimals, unlike USDC) with nonzero unclaimed fees, for cross-pool isolation coverage
    uint256 internal constant UNI_FORK_TOKEN_ID = 107094;
    uint256 internal constant UNI_FORK_CURRENCY_FEES_AMOUNT = 261556308004307;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    BuybackAndBurnPositionRecipient internal positionRecipient;
    MockLPFeesExecutor internal executor;

    function setUp() public override {
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        executor = new MockLPFeesExecutor();
    }

    function _getPositionRecipient(uint64 _timelockBlockNumber)
        internal
        override
        returns (ITimelockedPositionRecipient)
    {
        return new BuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, 1
        );
    }

    function test_CanBeConstructed(uint256 _timelockBlockNumber, uint256 _minTokenBurnAmount) public {
        vm.assume(_minTokenBurnAmount > 0);
        positionRecipient = new BuybackAndBurnPositionRecipient(
            IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, _minTokenBurnAmount
        );

        assertEq(positionRecipient.timelockBlockNumber(), _timelockBlockNumber);
        assertEq(positionRecipient.minCurrency1BurnAmount(), _minTokenBurnAmount);
        assertEq(Currency.unwrap(positionRecipient.currency()), NATIVE);
        assertEq(positionRecipient.operator(), operator);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
    }

    function test_RevertsIfMinTokenBurnAmountIsZero(uint256 _timelockBlockNumber) public {
        vm.expectRevert(BuybackAndBurnPositionRecipient.InvalidMinCurrency1BurnAmount.selector);
        new BuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, _timelockBlockNumber, 0);
    }

    function test_collectFees_revertsIfPositionIsInvalid() public {
        positionRecipient = new BuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);

        vm.expectRevert(abi.encodeWithSelector(ILPFeesPositionRecipient.InvalidPosition.selector, type(uint256).max));
        positionRecipient.collectFees(type(uint256).max, 0, 0);
    }

    function test_onFeesReceived_recordsFeesWithoutPositionOwnership() public {
        positionRecipient = new BuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);
        _notifyNativeFees(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT);

        (uint256 currency0Fees, uint256 currency1Fees) = positionRecipient.fees(FORK_TOKEN_ID);
        assertEq(currency0Fees, FORK_CURRENCY0_FEES_AMOUNT);
        assertEq(currency1Fees, 0);
    }

    function test_collectFees_derivesTokenAndPreservesExistingETH(uint256 _minTokenBurnAmount) public {
        _minTokenBurnAmount = bound(_minTokenBurnAmount, 1, 1_000_000e6);
        positionRecipient =
            new BuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, _minTokenBurnAmount);

        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), _minTokenBurnAmount);
        uint256 existingETH = 1 ether;
        vm.deal(address(positionRecipient), existingETH);
        _notifyNativeFees(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT);
        uint256 executorETHBefore = address(executor).balance;
        uint256 burnAddressTokenBefore = IERC20(USDC).balanceOf(address(0xdead));

        vm.expectEmit(true, true, false, true);
        emit BuybackAndBurnPositionRecipient.TokensBurned(FORK_TOKEN_ID, Currency.wrap(USDC), _minTokenBurnAmount);
        vm.expectEmit(true, false, false, false, address(positionRecipient));
        emit ILPFeesPositionRecipient.FeesCollected(
            FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0, _poolKey(FORK_TOKEN_ID)
        );
        executor.execute(positionRecipient, FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0);

        assertEq(address(positionRecipient).balance, existingETH);
        assertEq(address(executor).balance - executorETHBefore, FORK_CURRENCY0_FEES_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(0xdead)), burnAddressTokenBefore + _minTokenBurnAmount);
    }

    function test_collectFees_revertsIfCurrencyIsNotNative() public {
        positionRecipient = new BuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackAndBurnPositionRecipient.InvalidCurrency.selector,
                Currency.wrap(NON_ETH_FORK_CURRENCY0),
                Currency.wrap(NATIVE)
            )
        );
        executor.execute(positionRecipient, NON_ETH_FORK_TOKEN_ID, 0, 0);
    }

    function test_collectFees_revertsIfInsufficientCurrencyReceived(uint256 _minCurrencyAmount) public {
        _minCurrencyAmount = _bound(_minCurrencyAmount, FORK_CURRENCY0_FEES_AMOUNT + 1, type(uint256).max);

        positionRecipient = new BuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);
        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), 1);
        _notifyNativeFees(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT);

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

    function test_collectFees_isolatesFeesAcrossPools() public {
        positionRecipient = new BuybackAndBurnPositionRecipient(IPositionManager(POSITION_MANAGER), operator, 0, 1);

        // One singleton instance holds positions from two different ETH-paired pools,
        // one of them with an 18-decimal token (UNI)
        _notifyNativeFees(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT);
        _notifyNativeFees(UNI_FORK_TOKEN_ID, UNI_FORK_CURRENCY_FEES_AMOUNT);

        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        executor.approveToken(UNI, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), 1);
        _dealTokenFromPoolManager(UNI, address(executor), 1);

        uint256 executorETHBefore = address(executor).balance;
        uint256 recipientETHBefore = address(positionRecipient).balance;
        uint256 unattributedETH = recipientETHBefore - UNI_FORK_CURRENCY_FEES_AMOUNT - FORK_CURRENCY0_FEES_AMOUNT;
        uint256 burnAddressUNIBefore = IERC20(UNI).balanceOf(address(0xdead));

        // Collecting the ETH/UNI position pays out exactly its own fees; the min doubles as a floor
        executor.execute(positionRecipient, UNI_FORK_TOKEN_ID, UNI_FORK_CURRENCY_FEES_AMOUNT, 0);

        assertEq(address(executor).balance - executorETHBefore, UNI_FORK_CURRENCY_FEES_AMOUNT);
        assertEq(address(positionRecipient).balance, unattributedETH + FORK_CURRENCY0_FEES_AMOUNT);
        assertGt(IERC20(UNI).balanceOf(address(0xdead)), burnAddressUNIBefore);

        // The other pool's position is untouched and still collectable for its exact amount
        executor.execute(positionRecipient, FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0);

        assertEq(
            address(executor).balance - executorETHBefore, UNI_FORK_CURRENCY_FEES_AMOUNT + FORK_CURRENCY0_FEES_AMOUNT
        );
        assertEq(address(positionRecipient).balance, unattributedETH);
    }

    function _notifyNativeFees(uint256 tokenId, uint256 amount) internal {
        vm.deal(address(positionRecipient), address(positionRecipient).balance + amount);
        positionRecipient.onFeesReceived(tokenId, amount, 0);
    }
}
