// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IClaimableRecipient} from "../../src/interfaces/IClaimableRecipient.sol";
import {VestingClaimRecipient} from "../../src/periphery/VestingClaimRecipient.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {
    MockPositionManager,
    BaseClaimRecipientHarness
} from "./btt/positionRecipients/definitions/positionRecipients.sol";

/// @dev `claimFrom` source that reports one pair of amounts from `amounts` and pays another on `claim`, so the
///      gap between what a source promises and what it delivers is expressible. Reenters when a target is set.
contract MockClaimSource {
    /// @dev The puller rejects a source resolving positions against a different manager, so this is settable.
    IPositionManager public positionManager;

    Currency internal currency0;
    Currency internal currency1;
    uint128 internal reported0;
    uint128 internal reported1;
    uint256 internal payout0;
    uint256 internal payout1;
    VestingClaimRecipient internal reentryTarget;

    constructor(IPositionManager _positionManager) {
        positionManager = _positionManager;
    }

    function setPositionManager(IPositionManager _positionManager) external {
        positionManager = _positionManager;
    }

    function configure(
        Currency _currency0,
        Currency _currency1,
        uint128 _reported0,
        uint128 _reported1,
        uint256 _payout0,
        uint256 _payout1
    ) external {
        currency0 = _currency0;
        currency1 = _currency1;
        reported0 = _reported0;
        reported1 = _reported1;
        payout0 = _payout0;
        payout1 = _payout1;
    }

    function setReentryTarget(VestingClaimRecipient _target) external {
        reentryTarget = _target;
    }

    function amounts(uint256) external view returns (uint128, uint128) {
        return (reported0, reported1);
    }

    function claim(uint256 tokenId, uint256, uint256) external {
        if (address(reentryTarget) != address(0)) {
            reentryTarget.claimFrom(IClaimableRecipient(address(this)), tokenId, 0, 0);
        }
        if (payout0 != 0) currency0.transfer(msg.sender, payout0);
        if (payout1 != 0) currency1.transfer(msg.sender, payout1);
    }

    receive() external payable {}
}

/// @title VestingClaimRecipientClaimFromTest
/// @notice `claimFrom` coverage. The entry point lives on `VestingClaimRecipient` rather than the shared base,
///         so the source is what varies here, not the puller.
contract VestingClaimRecipientClaimFromTest is Test {
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant FEES_0 = 2 ether;
    uint256 internal constant FEES_1 = 3 ether;
    uint128 internal constant INITIAL_LIQUIDITY = 100 ether;

    MockPositionManager internal manager;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;

    VestingClaimRecipient internal puller;

    function setUp() public {
        manager = new MockPositionManager();
        tokenA = new MockERC20("Token A", "A", 1_000_000 ether, address(this));
        tokenB = new MockERC20("Token B", "B", 1_000_000 ether, address(this));
        Currency a = Currency.wrap(address(tokenA));
        Currency b = Currency.wrap(address(tokenB));
        (currency0, currency1) = a < b ? (a, b) : (b, a);
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.configure(poolKey, TOKEN_ID, FEES_0, FEES_1, INITIAL_LIQUIDITY, 1 ether);

        BaseClaimRecipientHarness pinned = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        puller = new VestingClaimRecipient(
            IPositionManager(address(manager)), uint128(FEES_0), uint128(FEES_1), IClaimableRecipient(address(pinned))
        );
    }

    function test_claimFrom_WhenCurrency0MinimumIsNotMet_Reverts(uint128 minimum) public {
        minimum = uint128(bound(minimum, FEES_0 + 1, type(uint128).max));
        MockClaimSource source = _deploySource(uint128(FEES_0), uint128(FEES_1), FEES_0, FEES_1);

        vm.expectRevert(VestingClaimRecipient.InsufficientAmounts.selector);
        puller.claimFrom(IClaimableRecipient(address(source)), TOKEN_ID, minimum, 0);
    }

    function test_claimFrom_WhenCurrency1MinimumIsNotMet_Reverts(uint128 minimum) public {
        minimum = uint128(bound(minimum, FEES_1 + 1, type(uint128).max));
        MockClaimSource source = _deploySource(uint128(FEES_0), uint128(FEES_1), FEES_0, FEES_1);

        vm.expectRevert(VestingClaimRecipient.InsufficientAmounts.selector);
        puller.claimFrom(IClaimableRecipient(address(source)), TOKEN_ID, 0, minimum);
    }

    function test_claimFrom_WhenBothMinimumsAreMet_PullsAndAttributes(uint128 minimum0, uint128 minimum1) public {
        minimum0 = uint128(bound(minimum0, 0, FEES_0));
        minimum1 = uint128(bound(minimum1, 0, FEES_1));
        MockClaimSource source = _deploySource(uint128(FEES_0), uint128(FEES_1), FEES_0, FEES_1);

        puller.claimFrom(IClaimableRecipient(address(source)), TOKEN_ID, minimum0, minimum1);

        (uint256 amounts0, uint256 amounts1) = puller.amounts(TOKEN_ID);
        assertEq(amounts0, FEES_0);
        assertEq(amounts1, FEES_1);
        assertEq(puller.totalAmounts(currency0), FEES_0);
        assertEq(puller.totalAmounts(currency1), FEES_1);
        assertEq(currency0.balanceOf(address(puller)), FEES_0);
        assertEq(currency1.balanceOf(address(puller)), FEES_1);
    }

    function test_claimFrom_WhenSourcePaysLessThanReported_Reverts() public {
        MockClaimSource source = _deploySource(uint128(FEES_0), 0, FEES_0 - 1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimableRecipient.InsufficientAmountReceived.selector, currency0, FEES_0 - 1, FEES_0
            )
        );
        puller.claimFrom(IClaimableRecipient(address(source)), TOKEN_ID, 0, 0);
    }

    function test_claimFrom_WhenSourceReenters_Reverts() public {
        MockClaimSource source = _deploySource(uint128(FEES_0), 0, FEES_0, 0);
        source.setReentryTarget(puller);

        vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
        puller.claimFrom(IClaimableRecipient(address(source)), TOKEN_ID, 0, 0);
    }

    function test_claimFrom_WhenSourceReportsZero_IsNoop() public {
        MockClaimSource source = _deploySource(0, 0, 0, 0);

        puller.claimFrom(IClaimableRecipient(address(source)), TOKEN_ID, 0, 0);

        (uint256 amounts0, uint256 amounts1) = puller.amounts(TOKEN_ID);
        assertEq(amounts0, 0);
        assertEq(amounts1, 0);
        assertEq(currency0.balanceOf(address(puller)), 0);
        assertEq(currency1.balanceOf(address(puller)), 0);
    }

    function test_claimFrom_WhenSourceUsesADifferentPositionManager_Reverts() public {
        MockClaimSource source = _deploySource(uint128(FEES_0), uint128(FEES_1), FEES_0, FEES_1);
        MockPositionManager foreign = new MockPositionManager();
        source.setPositionManager(IPositionManager(address(foreign)));

        vm.expectRevert(
            abi.encodeWithSelector(
                VestingClaimRecipient.InvalidPositionManager.selector,
                IPositionManager(address(foreign)),
                IPositionManager(address(manager))
            )
        );
        puller.claimFrom(IClaimableRecipient(address(source)), TOKEN_ID, 0, 0);

        // the guard precedes the pull, so the source keeps what it reported
        assertEq(currency0.balanceOf(address(source)), FEES_0);
        assertEq(currency1.balanceOf(address(source)), FEES_1);
    }

    function _deploySource(uint128 reported0, uint128 reported1, uint256 payout0, uint256 payout1)
        internal
        returns (MockClaimSource source)
    {
        source = new MockClaimSource(IPositionManager(address(manager)));
        source.configure(currency0, currency1, reported0, reported1, payout0, payout1);
        if (payout0 != 0) MockERC20(Currency.unwrap(currency0)).transfer(address(source), payout0);
        if (payout1 != 0) MockERC20(Currency.unwrap(currency1)).transfer(address(source), payout1);
    }
}
