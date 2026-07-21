// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
// Concrete PoolManager/PositionManager imports keep their artifacts in the build graph for deployCodeTo
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {AutoCompoundPositionRecipient} from "../../../../../src/periphery/AutoCompoundPositionRecipient.sol";
import {ITimelockedPositionRecipient} from "../../../../../src/interfaces/ITimelockedPositionRecipient.sol";

/// @title AutoCompoundPositionRecipientTestBase
/// @notice BTT tests for AutoCompoundPositionRecipient, run against both a native and an ERC20 currency0 fixture
///
/// constructor
/// ├── when the currencies are out of order or equal
/// │   └── it reverts with CurrenciesOutOfOrderOrEqual
/// ├── when the caller reward exceeds the maximum
/// │   └── it reverts with InvalidCallerRewardBps
/// ├── when the compound cap is zero
/// │   └── it reverts with InvalidMaxCompoundBps
/// ├── when the compound cap exceeds 100%
/// │   └── it reverts with InvalidMaxCompoundBps
/// └── when the parameters are valid
///     └── it sets the configuration
///
/// compound
/// ├── when a compound already executed in the current block
/// │   └── it reverts with AlreadyCompoundedThisBlock
/// ├── when the position does not exist
/// │   └── it reverts with CurrencyMismatch
/// ├── when the position pool currencies do not match
/// │   └── it reverts with CurrencyMismatch
/// ├── when the position is not owned by the recipient
/// │   └── it reverts with NotApproved
/// └── when the position is owned and the currencies match
///     ├── given the position has no fees and no rollover
///     │   └── it adds zero liquidity and succeeds
///     ├── given the position has accrued fees
///     │   ├── it pays the caller reward share of collected fees
///     │   ├── it adds liquidity to the position
///     │   ├── it stores the unspent budget as rollover
///     │   ├── it emits Compounded
///     │   └── given the budget exceeds the per-compound cap
///     │       ├── it adds exactly the capped liquidity
///     │       └── it rolls the excess budget over
///     └── given rollover exists from a previous compound
///         └── it deploys the rollover budget
///
/// sweep
/// ├── when the timelock has not passed
/// │   └── it reverts with Timelocked
/// ├── when the caller is not the operator
/// │   └── it reverts with NotOperator
/// └── when the operator calls after the timelock
///     ├── it transfers the full currency balance
///     └── it emits Swept
abstract contract AutoCompoundPositionRecipientTestBase is Test {
    using CurrencyLibrary for Currency;

    // Canonical v4 deployment addresses
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;
    uint128 constant POSITION_LIQUIDITY = 1_000e18;
    uint16 constant CALLER_REWARD_BPS = 100;
    uint16 constant MAX_COMPOUND_BPS = 1_000;
    uint256 constant MAX_BPS = 10_000;
    uint256 constant SWAP_AMOUNT = 100e18;

    bytes32 constant COMPOUNDED_TOPIC = keccak256("Compounded(address,uint256,uint128,uint256,uint256)");

    address operator = makeAddr("operator");
    address searcher = makeAddr("searcher");

    PoolSwapTest swapRouter;
    AutoCompoundPositionRecipient recipient;
    PoolKey poolKey;
    Currency currency0;
    Currency currency1;
    uint256 tokenId;

    /// @dev Fixture hook: concrete test contracts return the ordered currency pair for the pool under test
    function _createCurrencies() internal virtual returns (Currency, Currency);

    function setUp() public virtual {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        vm.deal(address(this), 1_000_000e18);

        (currency0, currency1) = _createCurrencies();
        poolKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(poolKey, SQRT_PRICE_1_1);

        if (!currency0.isAddressZero()) {
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        }
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);

        recipient = _newRecipient(currency0, currency1, CALLER_REWARD_BPS, MAX_COMPOUND_BPS, 0);
        tokenId = _mintPosition(poolKey, address(recipient), POSITION_LIQUIDITY);
    }

    /// @notice Receive refunds from position mints, swaps and sweeps
    receive() external payable {}

    // Helpers

    function _newToken() internal returns (Currency) {
        return Currency.wrap(address(new MockERC20("Token", "TKN", 1e30, address(this))));
    }

    function _newRecipient(Currency _c0, Currency _c1, uint16 _rewardBps, uint16 _compoundBps, uint256 _timelock)
        internal
        returns (AutoCompoundPositionRecipient)
    {
        return new AutoCompoundPositionRecipient(
            _c0, _c1, operator, POSITION_MANAGER, POOL_MANAGER, _timelock, _rewardBps, _compoundBps
        );
    }

    /// @notice Mints a full range position funded from this contract's balances
    function _mintPosition(PoolKey memory _key, address _owner, uint128 _liquidity)
        internal
        returns (uint256 _tokenId)
    {
        _tokenId = POSITION_MANAGER.nextTokenId();

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            _key, TICK_LOWER, TICK_UPPER, _liquidity, type(uint128).max, type(uint128).max, _owner, bytes("")
        );
        params[1] = abi.encode(_key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(_key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(_key.currency0, _key.currency1, address(this));

        // Full range liquidity at a 1:1 price requires at most `liquidity` of each currency (plus rounding)
        uint256 amount = uint256(_liquidity) + 1;
        MockERC20(Currency.unwrap(_key.currency1)).transfer(address(POSITION_MANAGER), amount);
        if (_key.currency0.isAddressZero()) {
            POSITION_MANAGER.modifyLiquidities{value: amount}(abi.encode(actions, params), block.timestamp);
        } else {
            MockERC20(Currency.unwrap(_key.currency0)).transfer(address(POSITION_MANAGER), amount);
            POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        }
    }

    /// @notice Creates a second pool with fresh ERC20 currencies and mints a position in it to `_owner`
    function _mintForeignPoolPosition(address _owner) internal returns (uint256 _tokenId, PoolKey memory _key) {
        Currency tokenA = _newToken();
        Currency tokenB = _newToken();
        (Currency c0, Currency c1) =
            Currency.unwrap(tokenA) < Currency.unwrap(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        _key = PoolKey({currency0: c0, currency1: c1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(address(0))});
        POOL_MANAGER.initialize(_key, SQRT_PRICE_1_1);
        _tokenId = _mintPosition(_key, _owner, POSITION_LIQUIDITY);
    }

    function _swap(bool _zeroForOne, uint256 _amountIn) internal {
        SwapParams memory params = SwapParams({
            zeroForOne: _zeroForOne,
            amountSpecified: -int256(_amountIn),
            sqrtPriceLimitX96: _zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        if (_zeroForOne && currency0.isAddressZero()) {
            swapRouter.swap{value: _amountIn}(poolKey, params, settings, "");
        } else {
            swapRouter.swap(poolKey, params, settings, "");
        }
    }

    /// @notice Accrues fees to in-range positions in both currencies by swapping back and forth
    function _generateFees(uint256 _amountIn) internal {
        _swap(true, _amountIn);
        _swap(false, _amountIn);
    }

    /// @notice Calls compound as `_caller` and decodes the emitted Compounded event
    function _compoundAndDecode(AutoCompoundPositionRecipient _recipient, address _caller, uint256 _tokenId)
        internal
        returns (uint128 liquidityAdded, uint256 collected0, uint256 collected1)
    {
        vm.recordLogs();
        vm.prank(_caller);
        uint128 returned = _recipient.compound(_tokenId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(_recipient) && logs[i].topics[0] == COMPOUNDED_TOPIC) {
                (liquidityAdded, collected0, collected1) = abi.decode(logs[i].data, (uint128, uint256, uint256));
                assertEq(liquidityAdded, returned, "event liquidity does not match return value");
                return (liquidityAdded, collected0, collected1);
            }
        }
        fail();
    }

    // constructor

    function test_Constructor_WhenCurrenciesOutOfOrderOrEqual_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                AutoCompoundPositionRecipient.CurrenciesOutOfOrderOrEqual.selector,
                Currency.unwrap(currency1),
                Currency.unwrap(currency0)
            )
        );
        _newRecipient(currency1, currency0, CALLER_REWARD_BPS, MAX_COMPOUND_BPS, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                AutoCompoundPositionRecipient.CurrenciesOutOfOrderOrEqual.selector,
                Currency.unwrap(currency1),
                Currency.unwrap(currency1)
            )
        );
        _newRecipient(currency1, currency1, CALLER_REWARD_BPS, MAX_COMPOUND_BPS, 0);
    }

    function test_Constructor_WhenCallerRewardExceedsMaximum_Reverts(uint16 _callerRewardBps) public {
        _callerRewardBps = uint16(bound(_callerRewardBps, 1_001, type(uint16).max));

        vm.expectRevert(
            abi.encodeWithSelector(AutoCompoundPositionRecipient.InvalidCallerRewardBps.selector, _callerRewardBps)
        );
        _newRecipient(currency0, currency1, _callerRewardBps, MAX_COMPOUND_BPS, 0);
    }

    function test_Constructor_WhenCompoundCapIsZero_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AutoCompoundPositionRecipient.InvalidMaxCompoundBps.selector, 0));
        _newRecipient(currency0, currency1, CALLER_REWARD_BPS, 0, 0);
    }

    function test_Constructor_WhenCompoundCapExceedsMaximum_Reverts(uint16 _maxCompoundBps) public {
        _maxCompoundBps = uint16(bound(_maxCompoundBps, 10_001, type(uint16).max));

        vm.expectRevert(
            abi.encodeWithSelector(AutoCompoundPositionRecipient.InvalidMaxCompoundBps.selector, _maxCompoundBps)
        );
        _newRecipient(currency0, currency1, CALLER_REWARD_BPS, _maxCompoundBps, 0);
    }

    function test_Constructor_WhenParametersValid_SetsConfiguration(
        uint16 _callerRewardBps,
        uint16 _maxCompoundBps,
        uint64 _timelockBlockNumber
    ) public {
        _callerRewardBps = uint16(bound(_callerRewardBps, 0, 1_000));
        _maxCompoundBps = uint16(bound(_maxCompoundBps, 1, 10_000));

        AutoCompoundPositionRecipient created =
            _newRecipient(currency0, currency1, _callerRewardBps, _maxCompoundBps, _timelockBlockNumber);

        assertEq(Currency.unwrap(created.currency0()), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(created.currency1()), Currency.unwrap(currency1));
        assertEq(created.operator(), operator);
        assertEq(address(created.positionManager()), address(POSITION_MANAGER));
        assertEq(address(created.poolManager()), address(POOL_MANAGER));
        assertEq(created.timelockBlockNumber(), _timelockBlockNumber);
        assertEq(created.callerRewardBps(), _callerRewardBps);
        assertEq(created.maxCompoundBps(), _maxCompoundBps);
    }

    // compound

    function test_Compound_WhenCompoundAlreadyExecutedThisBlock_Reverts() public {
        _generateFees(SWAP_AMOUNT);
        recipient.compound(tokenId);

        vm.expectRevert(AutoCompoundPositionRecipient.AlreadyCompoundedThisBlock.selector);
        recipient.compound(tokenId);
    }

    function test_Compound_WhenPositionDoesNotExist_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(AutoCompoundPositionRecipient.CurrencyMismatch.selector, address(0), address(0))
        );
        recipient.compound(424242);
    }

    function test_Compound_WhenPoolCurrenciesDoNotMatch_Reverts() public {
        // A position in another pool transferred to the recipient must never deploy the recipient's balances
        (uint256 foreignTokenId, PoolKey memory foreignKey) = _mintForeignPoolPosition(address(recipient));

        vm.expectRevert(
            abi.encodeWithSelector(
                AutoCompoundPositionRecipient.CurrencyMismatch.selector, foreignKey.currency0, foreignKey.currency1
            )
        );
        recipient.compound(foreignTokenId);
    }

    function test_Compound_WhenPositionNotOwned_Reverts() public {
        uint256 foreignOwnedTokenId = _mintPosition(poolKey, address(this), POSITION_LIQUIDITY);

        vm.expectRevert(abi.encodeWithSelector(IPositionManager.NotApproved.selector, address(recipient)));
        recipient.compound(foreignOwnedTokenId);
    }

    function test_Compound_GivenNoFeesAndNoRollover_AddsZeroLiquidity() public {
        uint128 liquidityBefore = POSITION_MANAGER.getPositionLiquidity(tokenId);

        (uint128 liquidityAdded, uint256 collected0, uint256 collected1) =
            _compoundAndDecode(recipient, searcher, tokenId);

        assertEq(liquidityAdded, 0);
        assertEq(collected0, 0);
        assertEq(collected1, 0);
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), liquidityBefore);
        (uint256 rollover0, uint256 rollover1) = recipient.rollover(tokenId);
        assertEq(rollover0, 0);
        assertEq(rollover1, 0);
    }

    function test_Compound_GivenAccruedFees_PaysCallerRewardShareOfCollectedFees() public {
        _generateFees(SWAP_AMOUNT);
        uint256 searcherBalance0Before = currency0.balanceOf(searcher);
        uint256 searcherBalance1Before = currency1.balanceOf(searcher);

        (, uint256 collected0, uint256 collected1) = _compoundAndDecode(recipient, searcher, tokenId);

        assertGt(collected0, 0, "no currency0 fees collected");
        assertGt(collected1, 0, "no currency1 fees collected");
        assertEq(currency0.balanceOf(searcher) - searcherBalance0Before, collected0 * CALLER_REWARD_BPS / MAX_BPS);
        assertEq(currency1.balanceOf(searcher) - searcherBalance1Before, collected1 * CALLER_REWARD_BPS / MAX_BPS);
    }

    function test_Compound_GivenAccruedFees_AddsLiquidityToThePosition() public {
        _generateFees(SWAP_AMOUNT);
        uint128 liquidityBefore = POSITION_MANAGER.getPositionLiquidity(tokenId);

        (uint128 liquidityAdded,,) = _compoundAndDecode(recipient, searcher, tokenId);

        assertGt(liquidityAdded, 0);
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), liquidityBefore + liquidityAdded);
    }

    function test_Compound_GivenAccruedFees_StoresUnspentBudgetAsRollover() public {
        _generateFees(SWAP_AMOUNT);

        _compoundAndDecode(recipient, searcher, tokenId);

        // The recipient's remaining balances are exactly the recorded rollover budget
        (uint256 rollover0, uint256 rollover1) = recipient.rollover(tokenId);
        assertEq(rollover0, currency0.balanceOf(address(recipient)));
        assertEq(rollover1, currency1.balanceOf(address(recipient)));
    }

    function test_Compound_GivenAccruedFees_EmitsCompounded() public {
        _generateFees(SWAP_AMOUNT);

        vm.expectEmit(true, true, false, false, address(recipient));
        emit AutoCompoundPositionRecipient.Compounded(searcher, tokenId, 0, 0, 0);
        vm.prank(searcher);
        recipient.compound(tokenId);
    }

    function test_Compound_GivenBudgetExceedsCap_AddsExactlyTheCappedLiquidity() public {
        // A dedicated recipient with a 0.01% growth cap and its own equally sized position
        AutoCompoundPositionRecipient capped = _newRecipient(currency0, currency1, CALLER_REWARD_BPS, 1, 0);
        uint256 cappedTokenId = _mintPosition(poolKey, address(capped), POSITION_LIQUIDITY);
        _generateFees(SWAP_AMOUNT * 4);

        uint128 maxLiquidity = uint128(uint256(POSITION_MANAGER.getPositionLiquidity(cappedTokenId)) * 1 / MAX_BPS);
        (uint128 liquidityAdded,,) = _compoundAndDecode(capped, searcher, cappedTokenId);

        // it adds exactly the capped liquidity
        assertEq(liquidityAdded, maxLiquidity);
        // it rolls the excess budget over
        (uint256 rollover0, uint256 rollover1) = capped.rollover(cappedTokenId);
        assertGt(rollover0 + rollover1, 0, "excess budget was not rolled over");
    }

    function test_Compound_GivenRolloverFromPreviousCompound_DeploysTheRolloverBudget() public {
        AutoCompoundPositionRecipient capped = _newRecipient(currency0, currency1, CALLER_REWARD_BPS, 1, 0);
        uint256 cappedTokenId = _mintPosition(poolKey, address(capped), POSITION_LIQUIDITY);
        _generateFees(SWAP_AMOUNT * 4);
        _compoundAndDecode(capped, searcher, cappedTokenId);
        (uint256 rollover0Before, uint256 rollover1Before) = capped.rollover(cappedTokenId);
        assertGt(rollover0Before + rollover1Before, 0);

        vm.roll(block.number + 1);
        (uint128 liquidityAdded, uint256 collected0, uint256 collected1) =
            _compoundAndDecode(capped, searcher, cappedTokenId);

        // No new fees were generated: the entire deployed budget came from rollover
        assertEq(collected0, 0);
        assertEq(collected1, 0);
        assertGt(liquidityAdded, 0);
        (uint256 rollover0After, uint256 rollover1After) = capped.rollover(cappedTokenId);
        assertLt(rollover0After + rollover1After, rollover0Before + rollover1Before);
    }

    // sweep

    function test_Sweep_WhenTimelockHasNotPassed_Reverts() public {
        AutoCompoundPositionRecipient locked =
            _newRecipient(currency0, currency1, CALLER_REWARD_BPS, MAX_COMPOUND_BPS, block.number + 1_000);

        vm.expectRevert(ITimelockedPositionRecipient.Timelocked.selector);
        vm.prank(operator);
        locked.sweep(currency1, operator);
    }

    function test_Sweep_WhenCallerIsNotOperator_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AutoCompoundPositionRecipient.NotOperator.selector, searcher));
        vm.prank(searcher);
        recipient.sweep(currency1, searcher);
    }

    function test_Sweep_WhenOperatorCallsAfterTimelock_TransfersBalanceAndEmits(uint128 _amount) public {
        // Bound to the funds available to this test contract's fixture
        _amount = uint128(bound(_amount, 1, 1e27));
        address sweepRecipient = makeAddr("sweepRecipient");
        if (currency0.isAddressZero()) {
            vm.deal(address(recipient), _amount);
        } else {
            MockERC20(Currency.unwrap(currency0)).transfer(address(recipient), _amount);
        }

        vm.expectEmit(true, true, true, true, address(recipient));
        emit AutoCompoundPositionRecipient.Swept(currency0, sweepRecipient, _amount);
        vm.prank(operator);
        recipient.sweep(currency0, sweepRecipient);

        assertEq(currency0.balanceOf(sweepRecipient), _amount);
        assertEq(currency0.balanceOf(address(recipient)), 0);
    }
}

/// @notice Runs the suite against a pool with native currency0
contract AutoCompoundPositionRecipientNativeTest is AutoCompoundPositionRecipientTestBase {
    function _createCurrencies() internal override returns (Currency, Currency) {
        return (CurrencyLibrary.ADDRESS_ZERO, _newToken());
    }
}

/// @notice Runs the suite against a pool with two ERC20 currencies
contract AutoCompoundPositionRecipientERC20Test is AutoCompoundPositionRecipientTestBase {
    function _createCurrencies() internal override returns (Currency, Currency) {
        Currency tokenA = _newToken();
        Currency tokenB = _newToken();
        return Currency.unwrap(tokenA) < Currency.unwrap(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }
}
