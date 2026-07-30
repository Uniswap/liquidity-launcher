// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IClaimableRecipient} from "../../src/interfaces/IClaimableRecipient.sol";
import {BuybackAndBurnClaimRecipient} from "../../src/periphery/BuybackAndBurnClaimRecipient.sol";
import {PositionRecipientTestBase} from "./PositionRecipientTestBase.sol";
import {MockClaimExecutor} from "./MockClaimExecutor.sol";

contract BuybackAndBurnClaimRecipientTest is PositionRecipientTestBase {
    /// @dev An existing position at FORK_BLOCK whose currency0 is an ERC20, not native ETH
    uint256 internal constant NON_ETH_FORK_TOKEN_ID = 107193;
    address internal constant NON_ETH_FORK_CURRENCY0 = 0x18F52B3fb465118731d9e0d276d4Eb3599D57596;
    /// @dev An existing native ETH position at FORK_BLOCK in a different pool (ETH/UNI; UNI has
    ///      18 decimals, unlike USDC) with nonzero unclaimed fees, for cross-pool isolation coverage
    uint256 internal constant UNI_FORK_TOKEN_ID = 107094;
    uint256 internal constant UNI_FORK_CURRENCY_FEES_AMOUNT = 261556308004307;
    address internal constant UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    BuybackAndBurnClaimRecipient internal positionRecipient;
    MockClaimExecutor internal executor;

    function setUp() public override {
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        executor = new MockClaimExecutor();
    }

    function test_CanBeConstructed(uint256 _minTokenBurnAmount) public {
        vm.assume(_minTokenBurnAmount > 0);
        positionRecipient = new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), _minTokenBurnAmount);

        assertEq(positionRecipient.minCurrency1BurnAmount(), _minTokenBurnAmount);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
    }

    function test_CanReceiveETH() public {
        positionRecipient = new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        uint256 balanceBefore = address(positionRecipient).balance;
        vm.deal(address(this), 1 ether);
        (bool success,) = address(positionRecipient).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(positionRecipient).balance, balanceBefore + 1 ether);
    }

    function test_RevertsIfMinTokenBurnAmountIsZero() public {
        vm.expectRevert(BuybackAndBurnClaimRecipient.ZeroMinCurrency1BurnAmount.selector);
        new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), 0);
    }

    function test_claim_revertsIfPositionIsInvalid() public {
        positionRecipient = new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), 1);

        vm.expectRevert(abi.encodeWithSelector(IClaimableRecipient.InvalidPosition.selector, type(uint256).max));
        positionRecipient.claim(type(uint256).max, 0, 0);
    }

    function test_onAmountsReceived_recordsAmountsWithoutPositionOwnership() public {
        positionRecipient = new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        _notifyNativeAmounts(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT);

        (uint256 currency0Amount, uint256 currency1Amount) = positionRecipient.amounts(FORK_TOKEN_ID);
        assertEq(currency0Amount, FORK_CURRENCY0_FEES_AMOUNT);
        assertEq(currency1Amount, 0);
    }

    function test_claim_derivesTokenAndPreservesExistingETH(uint256 _minTokenBurnAmount) public {
        _minTokenBurnAmount = bound(_minTokenBurnAmount, 1, 1_000_000e6);
        positionRecipient = new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), _minTokenBurnAmount);

        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), _minTokenBurnAmount);
        uint256 existingETH = 1 ether;
        vm.deal(address(positionRecipient), existingETH);
        _notifyNativeAmounts(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT);
        uint256 executorETHBefore = address(executor).balance;
        uint256 burnAddressTokenBefore = IERC20(USDC).balanceOf(address(0xdead));

        vm.expectEmit(true, true, false, true);
        emit BuybackAndBurnClaimRecipient.TokensBurned(FORK_TOKEN_ID, Currency.wrap(USDC), _minTokenBurnAmount);
        vm.expectEmit(true, false, false, false, address(positionRecipient));
        emit IClaimableRecipient.Claimed(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0, _poolKey(FORK_TOKEN_ID));
        executor.execute(positionRecipient, FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0);

        assertEq(address(positionRecipient).balance, existingETH);
        assertEq(address(executor).balance - executorETHBefore, FORK_CURRENCY0_FEES_AMOUNT);
        assertEq(IERC20(USDC).balanceOf(address(0xdead)), burnAddressTokenBefore + _minTokenBurnAmount);
    }

    function test_claim_eoaCallerReverts_executorCallbackIsMandatory() public {
        uint256 burnAmount = 1_000e6;
        positionRecipient = new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), burnAmount);
        address collector = makeAddr("eoaCollector");
        _dealUSDCFromPoolManager(collector, burnAmount);
        vm.prank(collector);
        IERC20(USDC).approve(address(positionRecipient), burnAmount);
        _notifyNativeAmounts(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT);

        // Even a fully approved EOA cannot claim: the executor callback is mandatory.
        vm.prank(collector);
        vm.expectRevert();
        positionRecipient.claim(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0);

        (uint256 nativeAmount,) = positionRecipient.amounts(FORK_TOKEN_ID);
        assertEq(nativeAmount, FORK_CURRENCY0_FEES_AMOUNT);
    }

    function test_claim_revertsIfCurrencyIsNotNative() public {
        positionRecipient = new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackAndBurnClaimRecipient.InvalidCurrency.selector,
                Currency.wrap(NON_ETH_FORK_CURRENCY0),
                Currency.wrap(NATIVE)
            )
        );
        executor.execute(positionRecipient, NON_ETH_FORK_TOKEN_ID, 0, 0);
    }

    function test_claim_revertsIfInsufficientCurrencyReceived(uint256 _minCurrencyAmount) public {
        _minCurrencyAmount = _bound(_minCurrencyAmount, FORK_CURRENCY0_FEES_AMOUNT + 1, type(uint256).max);

        positionRecipient = new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        executor.approveToken(USDC, address(positionRecipient), type(uint256).max);
        _dealUSDCFromPoolManager(address(executor), 1);
        _notifyNativeAmounts(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimableRecipient.InsufficientAmountReceived.selector,
                Currency.wrap(NATIVE),
                FORK_CURRENCY0_FEES_AMOUNT,
                _minCurrencyAmount
            )
        );
        executor.execute(positionRecipient, FORK_TOKEN_ID, _minCurrencyAmount, 0);
    }

    function test_claim_isolatesAmountsAcrossPools() public {
        positionRecipient = new BuybackAndBurnClaimRecipient(IPositionManager(POSITION_MANAGER), 1);

        // One singleton instance holds positions from two different ETH-paired pools,
        // one of them with an 18-decimal token (UNI)
        _notifyNativeAmounts(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT);
        _notifyNativeAmounts(UNI_FORK_TOKEN_ID, UNI_FORK_CURRENCY_FEES_AMOUNT);

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

    function _notifyNativeAmounts(uint256 tokenId, uint256 amount) internal {
        vm.deal(address(positionRecipient), address(positionRecipient).balance + amount);
        positionRecipient.onAmountsReceived(tokenId, amount, 0);
    }
}
