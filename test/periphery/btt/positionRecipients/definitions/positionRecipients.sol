// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {MockERC20} from "../../../../mocks/MockERC20.sol";
import {IClaimExecutor} from "../../../../../src/interfaces/IClaimExecutor.sol";
import {IClaimableRecipient} from "../../../../../src/interfaces/IClaimableRecipient.sol";
import {IFeeSplitter} from "../../../../../src/interfaces/IFeeSplitter.sol";
import {ITimelockedPositionRecipient} from "../../../../../src/interfaces/ITimelockedPositionRecipient.sol";
import {BaseClaimRecipient} from "../../../../../src/periphery/BaseClaimRecipient.sol";
import {BaseClaimRecipientWithCallback} from "../../../../../src/periphery/BaseClaimRecipientWithCallback.sol";
import {BuybackAndBurnClaimRecipient} from "../../../../../src/periphery/BuybackAndBurnClaimRecipient.sol";
import {CompoundingClaimRecipient} from "../../../../../src/periphery/CompoundingClaimRecipient.sol";
import {TimelockedPositionRecipient} from "../../../../../src/periphery/TimelockedPositionRecipient.sol";
import {MockClaimExecutor} from "../../../MockClaimExecutor.sol";
import {MockCompoundingClaimExecutor} from "../../../MockCompoundingClaimExecutor.sol";
import {MockBuybackAndBurnClaimExecutor} from "../../../MockBuybackAndBurnClaimExecutor.sol";

contract MockPositionManager {
    PoolKey internal poolKey;
    uint256 internal validTokenId;
    uint256 internal fee0;
    uint256 internal fee1;
    uint128 internal liquidity;
    uint128 internal liquidityIncrease;

    address public approvedOperator;
    bool public operatorApproved;

    function configure(
        PoolKey memory _poolKey,
        uint256 _validTokenId,
        uint256 _fee0,
        uint256 _fee1,
        uint128 _liquidity,
        uint128 _liquidityIncrease
    ) external {
        poolKey = _poolKey;
        validTokenId = _validTokenId;
        fee0 = _fee0;
        fee1 = _fee1;
        liquidity = _liquidity;
        liquidityIncrease = _liquidityIncrease;
    }

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, PositionInfo) {
        if (tokenId != validTokenId) {
            return (
                PoolKey(Currency.wrap(address(0)), Currency.wrap(address(0)), 0, 0, IHooks(address(0))),
                PositionInfo.wrap(0)
            );
        }
        return (poolKey, PositionInfo.wrap(0));
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128) {
        if (tokenId != validTokenId) return 0;
        return liquidity;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        if (uint8(actions[0]) == uint8(Actions.DECREASE_LIQUIDITY)) {
            (Currency currency0, Currency currency1, address recipient) =
                abi.decode(params[1], (Currency, Currency, address));
            if (fee0 != 0) currency0.transfer(recipient, fee0);
            if (fee1 != 0) currency1.transfer(recipient, fee1);
        } else {
            liquidity += liquidityIncrease;
        }
    }

    function increaseLiquidity(uint256, uint256, uint128, uint128, bytes calldata) external {
        liquidity += liquidityIncrease;
    }

    function setApprovalForAll(address operator, bool approved) external {
        approvedOperator = operator;
        operatorApproved = approved;
    }

    receive() external payable {}
}

contract MockReentrantERC20 is MockERC20 {
    IClaimableRecipient internal immutable recipient;
    uint256 internal immutable tokenId;
    uint256 internal immutable currency1Amount;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    constructor(IClaimableRecipient _recipient, uint256 _tokenId, uint256 _currency1Amount, uint256 initialSupply)
        MockERC20("Reentrant Token", "REENTRANT", initialSupply, msg.sender)
    {
        recipient = _recipient;
        tokenId = _tokenId;
        currency1Amount = _currency1Amount;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool success = super.transfer(to, amount);
        if (!reentryAttempted && msg.sender == address(recipient)) {
            reentryAttempted = true;
            (reentrySucceeded, reentryRevertData) =
                address(recipient).call(abi.encodeCall(recipient.onAmountsReceived, (tokenId, 0, currency1Amount)));
        }
        return success;
    }
}

contract BaseClaimRecipientHarness is BaseClaimRecipient {
    constructor(IPositionManager positionManager) BaseClaimRecipient(positionManager) {}
}

/// @dev Callback-flavoured harness: inherits the executor-callback base so `claim` runs the mandatory
///      onClaimed callback (with the before/after hooks) — the surface the callback tests exercise.
contract BaseClaimRecipientWithCallbackHarness is BaseClaimRecipientWithCallback {
    constructor(IPositionManager positionManager) BaseClaimRecipientWithCallback(positionManager) {}
}

contract RevertingLPFeesExecutor is MockClaimExecutor {
    error CallbackFailed();

    function onClaimed(PoolKey memory, uint256, uint256, uint256) public pure override {
        revert CallbackFailed();
    }
}

contract ReentrantLPFeesExecutor is IClaimExecutor {
    IClaimableRecipient internal recipient;
    uint256 internal tokenId;

    function execute(IClaimableRecipient _recipient, uint256 _tokenId) external {
        recipient = _recipient;
        tokenId = _tokenId;
        recipient.claim(_tokenId, 0, 0);
    }

    function onClaimed(PoolKey memory, uint256, uint256, uint256) external {
        recipient.claim(tokenId, 0, 0);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IClaimExecutor).interfaceId;
    }

    receive() external payable {}
}

/// @title PositionRecipientsBTTTest
/// @notice BTT unit tests for the position-recipient family
///
/// TimelockedPositionRecipient
/// ├── when the timelock has not passed
/// │   └── it reverts
/// └── when the timelock has passed
///     └── it approves the operator
///
/// BaseClaimRecipient
/// ├── when either minimum is not met
/// │   └── it reverts for the corresponding currency
/// └── when currency0 transfer reenters fee notification
///     └── it cannot attribute currency1 again
///
/// BaseClaimRecipientWithCallback
/// ├── when the executor callback reverts
/// │   └── it rolls back the claim
/// ├── when the executor callback reenters
/// │   └── it reverts
/// └── when both minimums are met
///     └── it transfers both amounts and invokes the executor
///
/// BuybackAndBurnClaimRecipient
/// ├── when currency0 is not native
/// │   └── it reverts
/// └── when currency0 is native
///     └── it burns currency1
///
/// CompoundingClaimRecipient
/// ├── when the liquidity increase is below the minimum
/// │   └── it reverts
/// └── when the executor deposits both currencies
///     └── it increases liquidity
contract PositionRecipientsBTTTest is Test {
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant FEES_0 = 2 ether;
    uint256 internal constant FEES_1 = 3 ether;
    uint128 internal constant INITIAL_LIQUIDITY = 100 ether;

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");

    MockPositionManager internal manager;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    function setUp() public {
        manager = new MockPositionManager();
        tokenA = new MockERC20("Token A", "A", 1_000_000 ether, address(this));
        tokenB = new MockERC20("Token B", "B", 1_000_000 ether, address(this));
        Currency a = Currency.wrap(address(tokenA));
        Currency b = Currency.wrap(address(tokenB));
        (currency0, currency1) = a < b ? (a, b) : (b, a);
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        _configure(poolKey, FEES_0, FEES_1, 1 ether);
    }

    function test_TimelockedPositionRecipient_WhenTimelockHasNotPassed_Reverts(uint64 timelock) public {
        timelock = uint64(bound(timelock, 1, type(uint64).max));
        TimelockedPositionRecipient recipient =
            new TimelockedPositionRecipient(IPositionManager(address(manager)), operator, timelock);
        vm.roll(uint256(timelock) - 1);

        vm.expectRevert(ITimelockedPositionRecipient.Timelocked.selector);
        recipient.approveOperator();
    }

    function test_TimelockedPositionRecipient_WhenTimelockHasPassed_ApprovesOperator(uint64 timelock) public {
        TimelockedPositionRecipient recipient =
            new TimelockedPositionRecipient(IPositionManager(address(manager)), operator, timelock);
        vm.roll(uint256(timelock) + 1);

        recipient.approveOperator();

        assertEq(manager.approvedOperator(), operator);
        assertTrue(manager.operatorApproved());
    }

    function test_BaseRecipient_WhenPositionDoesNotExist_NotificationReverts() public {
        BaseClaimRecipientHarness recipient = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        uint256 invalidTokenId = TOKEN_ID + 1;

        vm.expectRevert(abi.encodeWithSelector(IClaimableRecipient.InvalidPosition.selector, invalidTokenId));
        recipient.onAmountsReceived(invalidTokenId, 1, 0);
    }

    function test_BaseRecipient_WhenNotifiedAmountWasNotReceived_Reverts() public {
        BaseClaimRecipientHarness recipient = new BaseClaimRecipientHarness(IPositionManager(address(manager)));

        vm.expectRevert(
            abi.encodeWithSelector(IClaimableRecipient.InsufficientAmountReceived.selector, currency0, 0, FEES_0)
        );
        recipient.onAmountsReceived(TOKEN_ID, FEES_0, 0);
    }

    function test_BaseRecipient_WhenBalanceIsAlreadyAttributed_CannotAttributeItAgain() public {
        BaseClaimRecipientHarness recipient = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        MockERC20(Currency.unwrap(currency0)).transfer(address(recipient), FEES_0);
        recipient.onAmountsReceived(TOKEN_ID, FEES_0, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimableRecipient.InsufficientAmountReceived.selector, currency0, FEES_0, FEES_0 * 2
            )
        );
        recipient.onAmountsReceived(TOKEN_ID, FEES_0, 0);
    }

    function test_BaseRecipient_WhenCurrency0TransferReenters_CannotAttributeCurrency1Again() public {
        BaseClaimRecipientHarness recipient = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        MockReentrantERC20 reentrantToken = new MockReentrantERC20(recipient, TOKEN_ID, FEES_1, 1_000_000 ether);
        MockERC20 honestToken = new MockERC20("Honest Token", "HONEST", 1_000_000 ether, address(this));
        PoolKey memory reentrantPool = PoolKey(
            Currency.wrap(address(reentrantToken)), Currency.wrap(address(honestToken)), 3000, 60, IHooks(address(0))
        );
        _configure(reentrantPool, FEES_0, FEES_1, 1 ether);
        _notifyAmounts(recipient, reentrantPool, FEES_0, FEES_1);
        MockClaimExecutor executor = new MockClaimExecutor();

        executor.execute(recipient, TOKEN_ID, 0, 0);

        assertTrue(reentrantToken.reentryAttempted());
        assertFalse(reentrantToken.reentrySucceeded());
        assertEq(
            reentrantToken.reentryRevertData(),
            abi.encodeWithSelector(
                IClaimableRecipient.InsufficientAmountReceived.selector, reentrantPool.currency1, FEES_1, FEES_1 * 2
            )
        );
        assertEq(reentrantPool.currency0.balanceOf(address(executor)), FEES_0);
        assertEq(reentrantPool.currency1.balanceOf(address(executor)), FEES_1);
        (uint256 amounts0, uint256 amounts1) = recipient.amounts(TOKEN_ID);
        assertEq(amounts0, 0);
        assertEq(amounts1, 0);
        assertEq(recipient.totalAmounts(reentrantPool.currency0), 0);
        assertEq(recipient.totalAmounts(reentrantPool.currency1), 0);
    }

    function test_BaseRecipient_WhenCurrency0MinimumIsNotMet_Reverts(uint256 minimum) public {
        minimum = bound(minimum, FEES_0 + 1, type(uint128).max);
        BaseClaimRecipientHarness recipient = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        MockClaimExecutor executor = new MockClaimExecutor();
        _notifyAmounts(recipient, poolKey, FEES_0, FEES_1);

        vm.expectRevert(
            abi.encodeWithSelector(IClaimableRecipient.InsufficientAmountReceived.selector, currency0, FEES_0, minimum)
        );
        executor.execute(recipient, TOKEN_ID, minimum, 0);
    }

    function test_BaseRecipient_WhenCurrency1MinimumIsNotMet_Reverts(uint256 minimum) public {
        minimum = bound(minimum, FEES_1 + 1, type(uint128).max);
        BaseClaimRecipientHarness recipient = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        MockClaimExecutor executor = new MockClaimExecutor();
        _notifyAmounts(recipient, poolKey, FEES_0, FEES_1);

        vm.expectRevert(
            abi.encodeWithSelector(IClaimableRecipient.InsufficientAmountReceived.selector, currency1, FEES_1, minimum)
        );
        executor.execute(recipient, TOKEN_ID, 0, minimum);
    }

    function test_BaseRecipient_WhenBothMinimumsAreMet_TransfersAmountsAndInvokesExecutor(
        uint256 minimum0,
        uint256 minimum1
    ) public {
        minimum0 = bound(minimum0, 0, FEES_0);
        minimum1 = bound(minimum1, 0, FEES_1);
        BaseClaimRecipientWithCallbackHarness recipient =
            new BaseClaimRecipientWithCallbackHarness(IPositionManager(address(manager)));
        MockClaimExecutor executor = new MockClaimExecutor();
        _notifyAmounts(recipient, poolKey, FEES_0, FEES_1);

        executor.execute(recipient, TOKEN_ID, minimum0, minimum1);

        assertEq(executor.lastTokenId(), TOKEN_ID);
        assertEq(executor.lastCurrency0Received(), FEES_0);
        assertEq(executor.lastCurrency1Received(), FEES_1);
        assertEq(currency0.balanceOf(address(executor)), FEES_0);
        assertEq(currency1.balanceOf(address(executor)), FEES_1);
        (uint256 amounts0, uint256 amounts1) = recipient.amounts(TOKEN_ID);
        assertEq(amounts0, 0);
        assertEq(amounts1, 0);
        assertEq(recipient.totalAmounts(currency0), 0);
        assertEq(recipient.totalAmounts(currency1), 0);
    }

    function test_BaseRecipient_WhenExecutorCallbackReverts_RollsBackClaim() public {
        BaseClaimRecipientWithCallbackHarness recipient =
            new BaseClaimRecipientWithCallbackHarness(IPositionManager(address(manager)));
        RevertingLPFeesExecutor executor = new RevertingLPFeesExecutor();
        _notifyAmounts(recipient, poolKey, FEES_0, FEES_1);

        vm.expectRevert(RevertingLPFeesExecutor.CallbackFailed.selector);
        executor.execute(recipient, TOKEN_ID, 0, 0);

        assertEq(currency0.balanceOf(address(executor)), 0);
        assertEq(currency1.balanceOf(address(executor)), 0);
        (uint256 amounts0, uint256 amounts1) = recipient.amounts(TOKEN_ID);
        assertEq(amounts0, FEES_0);
        assertEq(amounts1, FEES_1);
    }

    function test_BaseRecipient_WhenExecutorCallbackReenters_Reverts() public {
        BaseClaimRecipientWithCallbackHarness recipient =
            new BaseClaimRecipientWithCallbackHarness(IPositionManager(address(manager)));
        ReentrantLPFeesExecutor executor = new ReentrantLPFeesExecutor();
        _notifyAmounts(recipient, poolKey, FEES_0, FEES_1);

        vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
        executor.execute(recipient, TOKEN_ID);
    }

    function test_BuybackAndBurn_WhenCurrency0IsNotNative_Reverts() public {
        BuybackAndBurnClaimRecipient recipient = new BuybackAndBurnClaimRecipient(IPositionManager(address(manager)), 1);
        MockClaimExecutor executor = new MockClaimExecutor();

        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackAndBurnClaimRecipient.InvalidCurrency.selector, poolKey.currency0, Currency.wrap(address(0))
            )
        );
        executor.execute(recipient, TOKEN_ID, 0, 0);
    }

    function test_BuybackAndBurn_WhenCurrency0IsNative_BurnsCurrency1(uint128 burnAmount) public {
        burnAmount = uint128(bound(burnAmount, 1, 100_000 ether));
        PoolKey memory nativePool = PoolKey(Currency.wrap(address(0)), currency1, 3000, 60, IHooks(address(0)));
        _configure(nativePool, FEES_0, FEES_1, 1 ether);
        BuybackAndBurnClaimRecipient recipient =
            new BuybackAndBurnClaimRecipient(IPositionManager(address(manager)), burnAmount);
        MockBuybackAndBurnClaimExecutor executor =
            new MockBuybackAndBurnClaimExecutor(Currency.unwrap(currency1), burnAmount);
        MockERC20(Currency.unwrap(currency1)).transfer(address(executor), burnAmount);
        uint256 burnedBefore = currency1.balanceOf(address(0xdead));
        _notifyAmounts(recipient, nativePool, FEES_0, FEES_1);

        executor.execute(recipient, TOKEN_ID, 0, 0);

        assertEq(currency1.balanceOf(address(0xdead)) - burnedBefore, burnAmount);
    }

    function test_Compounding_WhenLiquidityIncreaseIsBelowMinimum_Reverts() public {
        _configure(poolKey, FEES_0, FEES_1, 0);
        CompoundingClaimRecipient recipient = new CompoundingClaimRecipient(IPositionManager(address(manager)), 1);
        MockClaimExecutor executor = new MockClaimExecutor();

        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundingClaimRecipient.NotEnoughLiquidityAdded.selector,
                uint256(INITIAL_LIQUIDITY) + 1,
                INITIAL_LIQUIDITY
            )
        );
        executor.execute(recipient, TOKEN_ID, 0, 0);
    }

    function test_Compounding_WhenExecutorDepositsBothCurrencies_IncreasesLiquidity(uint128 liquidityIncrease) public {
        liquidityIncrease = uint128(bound(liquidityIncrease, 1, 100_000 ether));
        _configure(poolKey, FEES_0, FEES_1, liquidityIncrease);
        CompoundingClaimRecipient recipient =
            new CompoundingClaimRecipient(IPositionManager(address(manager)), liquidityIncrease);
        MockCompoundingClaimExecutor executor =
            new MockCompoundingClaimExecutor(IPositionManager(address(manager)), IWETH9(address(0)));
        executor.setFeeSplitter(IFeeSplitter(address(manager)), liquidityIncrease);
        _notifyAmounts(recipient, poolKey, FEES_0, FEES_1);

        executor.execute(recipient, TOKEN_ID, 0, 0);

        assertEq(manager.getPositionLiquidity(TOKEN_ID), INITIAL_LIQUIDITY + liquidityIncrease);
    }

    function _configure(PoolKey memory key, uint256 fee0, uint256 fee1, uint128 liquidityIncrease) internal {
        manager.configure(key, TOKEN_ID, fee0, fee1, INITIAL_LIQUIDITY, liquidityIncrease);
        if (key.currency0.isAddressZero()) {
            vm.deal(address(manager), fee0);
        } else {
            MockERC20(Currency.unwrap(key.currency0)).transfer(address(manager), fee0);
        }
        MockERC20(Currency.unwrap(key.currency1)).transfer(address(manager), fee1);
    }

    function _notifyAmounts(IClaimableRecipient recipient, PoolKey memory key, uint256 amount0, uint256 amount1)
        internal
    {
        if (key.currency0.isAddressZero()) {
            vm.deal(address(recipient), address(recipient).balance + amount0);
        } else {
            MockERC20(Currency.unwrap(key.currency0)).transfer(address(recipient), amount0);
        }
        MockERC20(Currency.unwrap(key.currency1)).transfer(address(recipient), amount1);
        recipient.onAmountsReceived(TOKEN_ID, amount0, amount1);
    }
}
