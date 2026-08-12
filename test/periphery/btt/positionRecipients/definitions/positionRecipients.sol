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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../../../../mocks/MockERC20.sol";
import {MockUERC20} from "../../../../mocks/MockUERC20.sol";
import {IClaimExecutor} from "../../../../../src/interfaces/IClaimExecutor.sol";
import {IClaimableRecipient} from "../../../../../src/interfaces/IClaimableRecipient.sol";
import {IFeeSplitter} from "../../../../../src/interfaces/IFeeSplitter.sol";
import {ITimelockedPositionRecipient} from "../../../../../src/interfaces/ITimelockedPositionRecipient.sol";
import {BaseClaimRecipient} from "../../../../../src/periphery/BaseClaimRecipient.sol";
import {BaseClaimRecipientWithCallback} from "../../../../../src/periphery/BaseClaimRecipientWithCallback.sol";
import {BuybackAndBurnClaimRecipient} from "../../../../../src/periphery/BuybackAndBurnClaimRecipient.sol";
import {CompoundingClaimRecipient} from "../../../../../src/periphery/CompoundingClaimRecipient.sol";
import {BeneficiaryVault} from "../../../../../src/periphery/BeneficiaryVault.sol";
import {UERC20BeneficiaryVault} from "../../../../../src/periphery/UERC20BeneficiaryVault.sol";
import {VestingClaimRecipient} from "../../../../../src/periphery/VestingClaimRecipient.sol";
import {IBeneficiaryVault} from "../../../../../src/interfaces/IBeneficiaryVault.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {TimelockedPositionRecipient} from "../../../../../src/periphery/TimelockedPositionRecipient.sol";
import {MockClaimExecutor} from "../../../MockClaimExecutor.sol";
import {MockCompoundingClaimExecutor} from "../../../MockCompoundingClaimExecutor.sol";
import {MockBuybackAndBurnClaimExecutor} from "../../../MockBuybackAndBurnClaimExecutor.sol";

contract MockPositionManager {
    error InvalidTokenId();

    PoolKey internal poolKey;
    uint256 internal validTokenId;
    uint256 internal fee0;
    uint256 internal fee1;
    uint128 internal liquidity;
    uint128 internal liquidityIncrease;
    address internal positionOwner;

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
        positionOwner = address(this);
    }

    function setPositionOwner(address owner) external {
        positionOwner = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        if (tokenId != validTokenId) revert InvalidTokenId();
        return positionOwner;
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

/// @dev Pinned recipient that passes the deploy-time manager check but rejects every notification, so the
///      rollback path stays reachable now that a mismatched manager is refused at construction.
contract RevertingNotificationRecipient {
    error NotificationRejected();

    IPositionManager public positionManager;

    constructor(IPositionManager _positionManager) {
        positionManager = _positionManager;
    }

    function onAmountsReceived(uint256, uint256, uint256) external pure {
        revert NotificationRejected();
    }

    receive() external payable {}
}

/// @dev ERC20 whose `graffiti()` returns fewer than 32 bytes so `_graffitiOf` treats it as unset.
contract MockShortGraffitiToken is MockERC20 {
    constructor(address recipient) MockERC20("Short Graffiti", "SHORT", 1_000_000 ether, recipient) {}

    function graffiti() external pure {
        assembly {
            mstore(0, 0x01)
            return(0, 1)
        }
    }
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
/// ├── when the executor deposits both currencies
/// │   └── it increases liquidity
///
/// BeneficiaryVault
/// ├── registerBeneficiary
/// │   ├── when the caller owns the position
/// │   │   └── it mints the beneficiary NFT to the recipient
/// │   ├── when the caller does not own the position
/// │   │   └── it reverts
/// │   ├── when the beneficiary is invalid
/// │   │   └── it reverts
/// │   ├── when the NFT already exists
/// │   │   └── it reverts
/// │   ├── when a new position owner tries to register again
/// │   │   └── it reverts and keeps the original beneficiary
/// │   └── when the position does not exist
/// │       └── it reverts
/// └── claim
///     ├── when registered
///     │   └── it pays the NFT owner
///     ├── when registered and the caller is not the beneficiary
///     │   └── it reverts
///     └── when unregistered
///         └── it flushes to the fallbacks
///
/// UERC20BeneficiaryVault
/// ├── registerBeneficiary
/// │   ├── when the caller owns the position
/// │   │   └── it mints the beneficiary NFT to the recipient
/// │   ├── when the caller matches currency1 graffiti
/// │   │   └── it mints the beneficiary NFT to the recipient
/// │   ├── when the caller matches currency0 graffiti
/// │   │   └── it mints the beneficiary NFT to the recipient
/// │   ├── when the caller specifies a different beneficiary
/// │   │   └── it mints to that address
/// │   ├── when the beneficiary is invalid
/// │   │   └── it reverts
/// │   ├── when the caller is not the position owner or token creator
/// │   │   └── it reverts
/// │   ├── when the NFT already exists
/// │   │   └── it reverts
/// │   └── when the position does not exist
/// │       └── it reverts
/// └── claim
///     ├── when unregistered and launcher graffiti is present
///     │   ├── when the caller is the token creator
///     │   │   └── it auto-registers and pays the caller
///     │   ├── when the caller is the position owner
///     │   │   └── it auto-registers and pays the caller
///     │   └── when the caller is neither the creator nor the position owner
///     │       └── it reverts without flushing
///     ├── when registered
///     │   └── it pays the NFT owner
///     ├── when registered and the caller is not the beneficiary
///     │   └── it reverts
///     └── when unregistered with no readable graffiti
///         └── it flushes to the fallbacks
///
/// VestingClaimRecipient
/// ├── constructor
/// │   ├── when the recipient is zero
/// │   │   └── it reverts
/// │   ├── when the recipient is the contract itself
/// │   │   └── it reverts
/// │   ├── when the recipient uses a different position manager
/// │   │   └── it reverts
/// │   ├── when the allowlist is empty
/// │   │   └── it reverts
/// │   ├── when an allowlisted vault uses a different position manager
/// │   │   └── it reverts
/// │   └── when the parameters are valid
/// │       └── it sets the configuration and allowlist
/// ├── onERC721Received
/// │   └── when a beneficiary NFT is safe transferred in
/// │       └── it accepts custody
/// ├── claimFrom
/// │   ├── when the vault is not allowlisted
/// │   │   └── it reverts
/// │   ├── when the puller does not own the beneficiary NFT
/// │   │   └── it reverts
/// │   ├── when the currency0 minimum is not met
/// │   │   └── it reverts
/// │   ├── when the currency1 minimum is not met
/// │   │   └── it reverts
/// │   ├── when the puller owns the NFT
/// │   │   └── it starts vesting, pulls and attributes
/// │   ├── when a later vault in the allowlist is selected
/// │   │   └── it pulls and attributes
/// │   └── when called after vesting has started
/// │       └── it preserves the original start block
/// └── claim
///     ├── when vesting has not started
///     │   └── it reverts
///     ├── when called in the vesting start block
///     │   └── it releases nothing
///     ├── when no amounts are available
///     │   └── it preserves the last claimed block
///     ├── when only currency0 is available
///     │   └── it releases currency0
///     ├── when only currency1 is available
///     │   └── it releases currency1
///     ├── when the available amount is below the per block maximum
///     │   └── it releases the full available amount
///     ├── when the available amount exceeds the per block maximum
///     │   └── it releases the accumulated cap
///     ├── when a claim was already processed this block
///     │   └── it releases nothing more
///     ├── when the caller is not the recipient
///     │   └── it still pays the pinned recipient
///     ├── when the recipient notification reverts
///     │   └── it rolls back the claim
///     └── when the position does not exist
///         └── it reverts
contract PositionRecipientsBTTTest is Test {
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant FEES_0 = 2 ether;
    uint256 internal constant FEES_1 = 3 ether;
    uint128 internal constant INITIAL_LIQUIDITY = 100 ether;
    address internal constant NATIVE_FALLBACK = address(0xdead);
    address internal constant TOKEN_FALLBACK = address(0xbeef);

    address internal operator = makeAddr("operator");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal creator = makeAddr("creator");
    address internal stranger = makeAddr("stranger");

    MockPositionManager internal manager;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal poolKey;
    BeneficiaryVault internal vestingVault;

    function setUp() public {
        manager = new MockPositionManager();
        tokenA = new MockERC20("Token A", "A", 1_000_000 ether, address(this));
        tokenB = new MockERC20("Token B", "B", 1_000_000 ether, address(this));
        Currency a = Currency.wrap(address(tokenA));
        Currency b = Currency.wrap(address(tokenB));
        (currency0, currency1) = a < b ? (a, b) : (b, a);
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        _configure(poolKey, FEES_0, FEES_1, 1 ether);
        vestingVault = new BeneficiaryVault(IPositionManager(address(manager)), NATIVE_FALLBACK, TOKEN_FALLBACK);
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

    function test_Vesting_claimFrom_WhenSourceIsVaultAndPullerDoesNotOwnNft_Reverts() public {
        (VestingClaimRecipient puller,) = _deployVesting(uint128(FEES_0), uint128(FEES_1));
        manager.setPositionOwner(address(this));
        vestingVault.registerBeneficiary(TOKEN_ID, feeRecipient);
        _notifyAmounts(vestingVault, poolKey, FEES_0, FEES_1);

        vm.expectRevert(abi.encodeWithSelector(VestingClaimRecipient.NotPositionOwner.selector, TOKEN_ID));
        puller.claimFrom(vestingVault, TOKEN_ID, 0, 0);
    }

    function test_Vesting_claimFrom_WhenSourceIsVaultAndPullerOwnsNft_PullsAndAttributes() public {
        (VestingClaimRecipient puller,) = _deployVesting(uint128(FEES_0), uint128(FEES_1));
        manager.setPositionOwner(address(this));
        vestingVault.registerBeneficiary(TOKEN_ID, address(puller));
        _notifyAmounts(vestingVault, poolKey, FEES_0, FEES_1);

        vm.expectEmit(true, false, false, true, address(puller));
        emit VestingClaimRecipient.VestingStarted(TOKEN_ID, block.number);
        puller.claimFrom(vestingVault, TOKEN_ID, 0, 0);

        (uint256 amounts0, uint256 amounts1) = puller.amounts(TOKEN_ID);
        assertEq(amounts0, FEES_0);
        assertEq(amounts1, FEES_1);
        assertEq(puller.lastClaimed(TOKEN_ID), block.number);
        (uint256 vault0, uint256 vault1) = vestingVault.amounts(TOKEN_ID);
        assertEq(vault0, 0);
        assertEq(vault1, 0);
    }

    function test_Vesting_claimFrom_WhenCurrency0MinimumIsNotMet_Reverts() public {
        (VestingClaimRecipient puller,) = _deployVesting(uint128(FEES_0), uint128(FEES_1));
        manager.setPositionOwner(address(this));
        vestingVault.registerBeneficiary(TOKEN_ID, address(puller));
        _notifyAmounts(vestingVault, poolKey, FEES_0, FEES_1);

        vm.expectRevert(VestingClaimRecipient.InsufficientAmounts.selector);
        puller.claimFrom(vestingVault, TOKEN_ID, uint128(FEES_0 + 1), 0);
        assertEq(puller.lastClaimed(TOKEN_ID), 0);
    }

    function test_Vesting_claimFrom_WhenCurrency1MinimumIsNotMet_Reverts() public {
        (VestingClaimRecipient puller,) = _deployVesting(uint128(FEES_0), uint128(FEES_1));
        manager.setPositionOwner(address(this));
        vestingVault.registerBeneficiary(TOKEN_ID, address(puller));
        _notifyAmounts(vestingVault, poolKey, FEES_0, FEES_1);

        vm.expectRevert(VestingClaimRecipient.InsufficientAmounts.selector);
        puller.claimFrom(vestingVault, TOKEN_ID, uint128(FEES_0), uint128(FEES_1 + 1));
        assertEq(puller.lastClaimed(TOKEN_ID), 0);
    }

    function test_Vesting_claimFrom_WhenVaultIsNotAllowlisted_Reverts() public {
        (VestingClaimRecipient puller,) = _deployVesting(uint128(FEES_0), uint128(FEES_1));
        BeneficiaryVault unallowlisted = _deployBeneficiaryVault();
        unallowlisted.registerBeneficiary(TOKEN_ID, address(puller));

        vm.expectRevert(
            abi.encodeWithSelector(
                VestingClaimRecipient.NotAllowlistedBeneficiaryVault.selector, IBeneficiaryVault(unallowlisted)
            )
        );
        puller.claimFrom(unallowlisted, TOKEN_ID, 0, 0);
        assertEq(puller.lastClaimed(TOKEN_ID), 0);
    }

    function test_Vesting_claimFrom_WhenSecondVaultIsAllowlisted_PullsAndAttributes() public {
        BeneficiaryVault second = _deployBeneficiaryVault();
        BaseClaimRecipientHarness pinned = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        IBeneficiaryVault[] memory allowlist = new IBeneficiaryVault[](2);
        allowlist[0] = vestingVault;
        allowlist[1] = second;
        VestingClaimRecipient puller = new VestingClaimRecipient(
            IPositionManager(address(manager)),
            uint128(FEES_0),
            uint128(FEES_1),
            IClaimableRecipient(address(pinned)),
            allowlist
        );
        second.registerBeneficiary(TOKEN_ID, address(puller));
        _notifyAmounts(second, poolKey, FEES_0, FEES_1);

        puller.claimFrom(second, TOKEN_ID, 0, 0);

        (uint256 amounts0, uint256 amounts1) = puller.amounts(TOKEN_ID);
        assertEq(amounts0, FEES_0);
        assertEq(amounts1, FEES_1);
    }

    function test_Vesting_claimFrom_WhenCalledAgain_DoesNotRestartVesting() public {
        (VestingClaimRecipient puller,) = _deployVesting(uint128(FEES_0), uint128(FEES_1));
        _startVesting(puller, FEES_0, FEES_1);
        uint256 startBlock = puller.lastClaimed(TOKEN_ID);

        vm.roll(block.number + 10);
        _notifyAmounts(vestingVault, poolKey, 1, 1);
        puller.claimFrom(vestingVault, TOKEN_ID, 0, 0);

        assertEq(puller.lastClaimed(TOKEN_ID), startBlock);
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

    function test_BeneficiaryVault_registerBeneficiary_WhenCallerOwnsPosition_MintsNft() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();
        address custodian = makeAddr("custodian");
        manager.setPositionOwner(custodian);

        vm.prank(custodian);
        vault.registerBeneficiary(TOKEN_ID, feeRecipient);

        assertEq(vault.ownerOf(TOKEN_ID), feeRecipient);
    }

    function test_BeneficiaryVault_registerBeneficiary_WhenCallerDoesNotOwnPosition_Reverts() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotPositionOwner.selector, TOKEN_ID, stranger));
        vault.registerBeneficiary(TOKEN_ID, feeRecipient);
    }

    function test_BeneficiaryVault_registerBeneficiary_WhenBeneficiaryIsZero_Reverts() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();

        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidBeneficiary.selector, address(0)));
        vault.registerBeneficiary(TOKEN_ID, address(0));
    }

    function test_BeneficiaryVault_registerBeneficiary_WhenBeneficiaryIsVault_Reverts() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();

        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidBeneficiary.selector, address(vault)));
        vault.registerBeneficiary(TOKEN_ID, address(vault));
    }

    function test_BeneficiaryVault_registerBeneficiary_WhenNftAlreadyExists_Reverts() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();

        vault.registerBeneficiary(TOKEN_ID, feeRecipient);

        vm.expectRevert(ERC721.TokenAlreadyExists.selector);
        vault.registerBeneficiary(TOKEN_ID, creator);
    }

    function test_BeneficiaryVault_registerBeneficiary_WhenNewPositionOwnerTriesAgain_RevertsAndKeepsOriginal() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();
        address originalBeneficiary = makeAddr("originalBeneficiary");
        address newCustodian = makeAddr("newCustodian");

        vault.registerBeneficiary(TOKEN_ID, originalBeneficiary);
        manager.setPositionOwner(newCustodian);

        vm.prank(newCustodian);
        vm.expectRevert(ERC721.TokenAlreadyExists.selector);
        vault.registerBeneficiary(TOKEN_ID, feeRecipient);

        assertEq(vault.ownerOf(TOKEN_ID), originalBeneficiary);
        assertEq(vault.balanceOf(originalBeneficiary), 1);
        assertEq(vault.balanceOf(feeRecipient), 0);
    }

    function test_BeneficiaryVault_registerBeneficiary_WhenPositionDoesNotExist_Reverts() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();
        uint256 invalidTokenId = TOKEN_ID + 1;

        vm.expectRevert(MockPositionManager.InvalidTokenId.selector);
        vault.registerBeneficiary(invalidTokenId, feeRecipient);
    }

    function test_BeneficiaryVault_claim_WhenRegistered_PaysOwner() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();
        _notifyAmounts(vault, poolKey, FEES_0, FEES_1);

        vault.registerBeneficiary(TOKEN_ID, feeRecipient);
        vm.prank(feeRecipient);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(feeRecipient), FEES_0);
        assertEq(IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(feeRecipient), FEES_1);
        (uint256 amount0, uint256 amount1) = vault.amounts(TOKEN_ID);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_BeneficiaryVault_claim_WhenRegisteredAndCallerIsNotBeneficiary_Reverts() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();
        _notifyAmounts(vault, poolKey, FEES_0, FEES_1);

        vault.registerBeneficiary(TOKEN_ID, feeRecipient);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotBeneficiary.selector, TOKEN_ID, stranger));
        vault.claim(TOKEN_ID, 0, 0);
    }

    function test_BeneficiaryVault_claim_WhenUnregistered_FlushesToFallbacks() public {
        BeneficiaryVault vault = _deployBeneficiaryVault();
        _notifyAmounts(vault, poolKey, FEES_0, FEES_1);

        vm.prank(stranger);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(TOKEN_FALLBACK), FEES_0);
        assertEq(IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(TOKEN_FALLBACK), FEES_1);
        (uint256 amount0, uint256 amount1) = vault.amounts(TOKEN_ID);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_UERC20Vault_registerBeneficiary_WhenCallerOwnsPosition_MintsNft() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        _nativeUerc20Pool(creator);
        address custodian = makeAddr("custodian");
        manager.setPositionOwner(custodian);

        vm.prank(custodian);
        vault.registerBeneficiary(TOKEN_ID, feeRecipient);

        assertEq(vault.ownerOf(TOKEN_ID), feeRecipient);
    }

    function test_UERC20Vault_registerBeneficiary_WhenCreatorMatchesCurrency1_MintsNft() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        _nativeUerc20Pool(creator);

        vm.prank(creator);
        vault.registerBeneficiary(TOKEN_ID, creator);

        assertEq(vault.ownerOf(TOKEN_ID), creator);
    }

    function test_UERC20Vault_registerBeneficiary_WhenCreatorMatchesCurrency0_MintsNft() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key, MockUERC20 launchToken,) = _tokenPairWithLaunchToken(creator);

        vm.prank(creator);
        vault.registerBeneficiary(TOKEN_ID, creator);

        assertEq(vault.ownerOf(TOKEN_ID), creator);
        assertEq(Currency.unwrap(key.currency0), address(launchToken));
    }

    function test_UERC20Vault_registerBeneficiary_WhenBeneficiaryIsSpecified_MintsToRecipient() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        _nativeUerc20Pool(creator);

        vm.prank(creator);
        vault.registerBeneficiary(TOKEN_ID, feeRecipient);

        assertEq(vault.ownerOf(TOKEN_ID), feeRecipient);
    }

    function test_UERC20Vault_registerBeneficiary_WhenBeneficiaryIsZero_Reverts() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        _nativeUerc20Pool(creator);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidBeneficiary.selector, address(0)));
        vault.registerBeneficiary(TOKEN_ID, address(0));
    }

    function test_UERC20Vault_registerBeneficiary_WhenBeneficiaryIsVault_Reverts() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        _nativeUerc20Pool(creator);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidBeneficiary.selector, address(vault)));
        vault.registerBeneficiary(TOKEN_ID, address(vault));
    }

    function test_UERC20Vault_registerBeneficiary_WhenCallerIsNotPositionOwnerOrCreator_Reverts() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        _nativeUerc20Pool(creator);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UERC20BeneficiaryVault.NotAuthorized.selector, TOKEN_ID, stranger));
        vault.registerBeneficiary(TOKEN_ID, creator);
    }

    function test_UERC20Vault_registerBeneficiary_WhenNftAlreadyExists_Reverts() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        _nativeUerc20Pool(creator);

        vm.prank(creator);
        vault.registerBeneficiary(TOKEN_ID, creator);

        vm.prank(creator);
        vm.expectRevert(ERC721.TokenAlreadyExists.selector);
        vault.registerBeneficiary(TOKEN_ID, creator);
    }

    function test_UERC20Vault_registerBeneficiary_WhenPositionDoesNotExist_Reverts() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        _nativeUerc20Pool(creator);
        uint256 invalidTokenId = TOKEN_ID + 1;

        vm.prank(creator);
        vm.expectRevert(MockPositionManager.InvalidTokenId.selector);
        vault.registerBeneficiary(invalidTokenId, creator);
    }

    function test_UERC20Vault_claim_WhenUnregisteredWithGraffiti_CreatorAutoRegistersAndPays() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key, MockUERC20 token) = _nativeUerc20Pool(creator);
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(creator);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(vault.ownerOf(TOKEN_ID), creator);
        assertEq(creator.balance, FEES_0);
        assertEq(token.balanceOf(creator), FEES_1);
        assertEq(NATIVE_FALLBACK.balance, 0);
        assertEq(token.balanceOf(TOKEN_FALLBACK), 0);
        (uint256 amount0, uint256 amount1) = vault.amounts(TOKEN_ID);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_UERC20Vault_claim_WhenUnregisteredWithGraffitiOnCurrency0_CreatorAutoRegistersAndPays() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key, MockUERC20 launchToken, MockERC20 other) = _tokenPairWithLaunchToken(creator);
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(creator);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(vault.ownerOf(TOKEN_ID), creator);
        assertEq(launchToken.balanceOf(creator), FEES_0);
        assertEq(other.balanceOf(creator), FEES_1);
    }

    function test_UERC20Vault_claim_WhenUnregisteredWithGraffiti_PositionOwnerAutoRegistersAndPays() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key, MockUERC20 token) = _nativeUerc20Pool(creator);
        address custodian = makeAddr("custodian");
        manager.setPositionOwner(custodian);
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(custodian);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(vault.ownerOf(TOKEN_ID), custodian);
        assertEq(custodian.balance, FEES_0);
        assertEq(token.balanceOf(custodian), FEES_1);
        assertEq(NATIVE_FALLBACK.balance, 0);
        assertEq(token.balanceOf(TOKEN_FALLBACK), 0);
        (uint256 amount0, uint256 amount1) = vault.amounts(TOKEN_ID);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_UERC20Vault_claim_WhenUnregisteredWithGraffiti_RevertsForStranger() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key, MockUERC20 token) = _nativeUerc20Pool(creator);
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UERC20BeneficiaryVault.NotAuthorized.selector, TOKEN_ID, stranger));
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(NATIVE_FALLBACK.balance, 0);
        assertEq(token.balanceOf(TOKEN_FALLBACK), 0);
    }

    function test_UERC20Vault_claim_WhenRegistered_PaysOwner() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key, MockUERC20 token) = _nativeUerc20Pool(creator);
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(creator);
        vault.registerBeneficiary(TOKEN_ID, creator);
        vm.prank(creator);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(creator.balance, FEES_0);
        assertEq(token.balanceOf(creator), FEES_1);
        (uint256 amount0, uint256 amount1) = vault.amounts(TOKEN_ID);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_UERC20Vault_claim_WhenRegisteredToDifferentBeneficiary_PaysBeneficiary() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key, MockUERC20 token) = _nativeUerc20Pool(creator);
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(creator);
        vault.registerBeneficiary(TOKEN_ID, feeRecipient);
        vm.prank(feeRecipient);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(creator.balance, 0);
        assertEq(token.balanceOf(creator), 0);
        assertEq(feeRecipient.balance, FEES_0);
        assertEq(token.balanceOf(feeRecipient), FEES_1);
    }

    function test_UERC20Vault_claim_WhenRegisteredAndCallerIsNotBeneficiary_Reverts() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key,) = _nativeUerc20Pool(creator);
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(creator);
        vault.registerBeneficiary(TOKEN_ID, creator);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotBeneficiary.selector, TOKEN_ID, stranger));
        vault.claim(TOKEN_ID, 0, 0);
    }

    function test_UERC20Vault_claim_WhenPlainTokenUnregistered_FlushesToFallbacks() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key, MockERC20 token) = _nativePlainPool();
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(stranger);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(NATIVE_FALLBACK.balance, FEES_0);
        assertEq(token.balanceOf(TOKEN_FALLBACK), FEES_1);
        (uint256 amount0, uint256 amount1) = vault.amounts(TOKEN_ID);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_UERC20Vault_claim_WhenGraffitiStaticcallFails_FlushesToFallbacks() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        (PoolKey memory key, MockUERC20 token) = _nativeUerc20Pool(creator);
        token.setGraffitiReverts(true);
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(stranger);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(NATIVE_FALLBACK.balance, FEES_0);
        assertEq(token.balanceOf(TOKEN_FALLBACK), FEES_1);
    }

    function test_UERC20Vault_claim_WhenGraffitiReturnsWrongLength_FlushesToFallbacks() public {
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        MockShortGraffitiToken token = new MockShortGraffitiToken(address(this));
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        _configureUerc20Pool(key, FEES_0, FEES_1);
        _notifyVault(vault, key, FEES_0, FEES_1);

        vm.prank(stranger);
        vault.claim(TOKEN_ID, 0, 0);

        assertEq(NATIVE_FALLBACK.balance, FEES_0);
        assertEq(token.balanceOf(TOKEN_FALLBACK), FEES_1);
    }

    function test_Vesting_constructor_WhenRecipientIsZero_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(VestingClaimRecipient.InvalidRecipient.selector, IClaimableRecipient(address(0)))
        );
        new VestingClaimRecipient(
            IPositionManager(address(manager)), 1 ether, 1 ether, IClaimableRecipient(address(0)), _vestingAllowlist()
        );
    }

    function test_Vesting_constructor_WhenRecipientIsSelf_Reverts() public {
        address self = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        vm.expectRevert(
            abi.encodeWithSelector(VestingClaimRecipient.InvalidRecipient.selector, IClaimableRecipient(self))
        );
        new VestingClaimRecipient(
            IPositionManager(address(manager)), 1 ether, 1 ether, IClaimableRecipient(self), _vestingAllowlist()
        );
    }

    function test_Vesting_constructor_WhenParametersAreValid_SetsConfiguration(uint128 max0, uint128 max1) public {
        max0 = uint128(bound(max0, 1, type(uint128).max));
        max1 = uint128(bound(max1, 1, type(uint128).max));
        (VestingClaimRecipient vesting, BaseClaimRecipientHarness pinned) = _deployVesting(max0, max1);

        assertEq(vesting.maxCurrency0PerBlock(), max0);
        assertEq(vesting.maxCurrency1PerBlock(), max1);
        assertEq(address(vesting.recipient()), address(pinned));
        assertEq(address(vesting.positionManager()), address(manager));
        assertEq(address(vesting.allowlistedBeneficiaryVaults(0)), address(vestingVault));
    }

    function test_Vesting_constructor_WhenAllowlistIsEmpty_Reverts() public {
        BaseClaimRecipientHarness pinned = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        IBeneficiaryVault[] memory allowlist = new IBeneficiaryVault[](0);

        vm.expectRevert(VestingClaimRecipient.MustSetAllowlistedBeneficiaryVaults.selector);
        new VestingClaimRecipient(
            IPositionManager(address(manager)), uint128(FEES_0), uint128(FEES_1), pinned, allowlist
        );
    }

    function test_Vesting_constructor_WhenAllowlistedVaultUsesADifferentPositionManager_Reverts() public {
        MockPositionManager foreignManager = new MockPositionManager();
        BeneficiaryVault foreign =
            new BeneficiaryVault(IPositionManager(address(foreignManager)), NATIVE_FALLBACK, TOKEN_FALLBACK);
        BaseClaimRecipientHarness pinned = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        IBeneficiaryVault[] memory allowlist = new IBeneficiaryVault[](2);
        allowlist[0] = vestingVault;
        allowlist[1] = foreign;

        vm.expectRevert(
            abi.encodeWithSelector(
                VestingClaimRecipient.InvalidPositionManager.selector,
                IPositionManager(address(foreignManager)),
                IPositionManager(address(manager))
            )
        );
        new VestingClaimRecipient(
            IPositionManager(address(manager)), uint128(FEES_0), uint128(FEES_1), pinned, allowlist
        );
    }

    function test_Vesting_onERC721Received_WhenNftIsSafeTransferredIn_AcceptsCustody() public {
        (VestingClaimRecipient vesting,) = _deployVesting(1 ether, 1 ether);
        UERC20BeneficiaryVault vault = _deployUerc20Vault();
        _nativeUerc20Pool(creator);
        manager.setPositionOwner(address(this));
        vault.registerBeneficiary(TOKEN_ID, address(this));

        vault.safeTransferFrom(address(this), address(vesting), TOKEN_ID);

        assertEq(vault.ownerOf(TOKEN_ID), address(vesting));
    }

    function test_Vesting_claim_WhenClaimAlreadyProcessedThisBlock_ReleasesNothingMore() public {
        uint128 max0 = uint128(FEES_0 / 10);
        uint128 max1 = uint128(FEES_1 / 10);
        (VestingClaimRecipient vesting, BaseClaimRecipientHarness pinned) = _deployVesting(max0, max1);
        _startVesting(vesting, FEES_0, FEES_1);

        vesting.claim(TOKEN_ID, 0, 0);
        assertEq(currency0.balanceOf(address(pinned)), 0);
        assertEq(currency1.balanceOf(address(pinned)), 0);

        vm.roll(block.number + 1);
        vesting.claim(TOKEN_ID, 0, 0);
        assertEq(currency0.balanceOf(address(pinned)), max0);

        vesting.claim(TOKEN_ID, 0, 0);

        assertEq(vesting.lastClaimed(TOKEN_ID), block.number);
        assertEq(currency0.balanceOf(address(pinned)), max0);
        assertEq(currency1.balanceOf(address(pinned)), max1);
    }

    function test_Vesting_claim_WhenAvailableIsBelowMax_ReleasesFullAmount() public {
        (VestingClaimRecipient vesting, BaseClaimRecipientHarness pinned) =
            _deployVesting(uint128(FEES_0), uint128(FEES_1));
        _startVesting(vesting, FEES_0, FEES_1);

        vm.roll(block.number + 1);
        vesting.claim(TOKEN_ID, 0, 0);

        assertEq(currency0.balanceOf(address(pinned)), FEES_0);
        assertEq(currency1.balanceOf(address(pinned)), FEES_1);
        (uint256 amounts0, uint256 amounts1) = vesting.amounts(TOKEN_ID);
        assertEq(amounts0, 0);
        assertEq(amounts1, 0);
        // the release is registered on the recipient through `_afterClaim`
        (uint256 pinned0, uint256 pinned1) = pinned.amounts(TOKEN_ID);
        assertEq(pinned0, FEES_0);
        assertEq(pinned1, FEES_1);
    }

    function test_Vesting_claim_WhenAvailableExceedsMax_ReleasesAccumulatedCap(uint256 rounds, uint256 gapBlocks)
        public
    {
        rounds = bound(rounds, 1, 5);
        gapBlocks = bound(gapBlocks, 1, 1000);
        uint128 max0 = uint128(FEES_0 / 10);
        uint128 max1 = uint128(FEES_1 / 10);
        (VestingClaimRecipient vesting, BaseClaimRecipientHarness pinned) = _deployVesting(max0, max1);
        _startVesting(vesting, FEES_0, FEES_1);

        for (uint256 i = 0; i < rounds; i++) {
            vm.roll(block.number + gapBlocks);
            vesting.claim(TOKEN_ID, 0, 0);
        }

        uint256 released0 = uint256(max0) * gapBlocks * rounds;
        uint256 released1 = uint256(max1) * gapBlocks * rounds;
        if (released0 > FEES_0) released0 = FEES_0;
        if (released1 > FEES_1) released1 = FEES_1;
        assertEq(currency0.balanceOf(address(pinned)), released0);
        assertEq(currency1.balanceOf(address(pinned)), released1);
        (uint256 amounts0, uint256 amounts1) = vesting.amounts(TOKEN_ID);
        assertEq(amounts0, FEES_0 - released0);
        assertEq(amounts1, FEES_1 - released1);
    }

    function test_Vesting_claim_WhenVestingHasNotStarted_Reverts() public {
        (VestingClaimRecipient vesting,) = _deployVesting(uint128(FEES_0), uint128(FEES_1));
        _notifyAmounts(vesting, poolKey, FEES_0, FEES_1);

        vm.expectRevert(abi.encodeWithSelector(VestingClaimRecipient.VestingNotStarted.selector, TOKEN_ID));
        vesting.claim(TOKEN_ID, 0, 0);
        assertEq(vesting.lastClaimed(TOKEN_ID), 0);
    }

    function test_Vesting_claim_WhenNoAmountsAreAvailable_DoesNotUpdateLastClaimed() public {
        (VestingClaimRecipient vesting,) = _deployVesting(uint128(FEES_0), uint128(FEES_1));
        _startVesting(vesting, 0, 0);
        uint256 startBlock = vesting.lastClaimed(TOKEN_ID);

        vm.roll(block.number + 10);
        vesting.claim(TOKEN_ID, 0, 0);

        assertEq(vesting.lastClaimed(TOKEN_ID), startBlock);
    }

    function test_Vesting_claim_WhenOnlyCurrency0IsAvailable_ReleasesCurrency0() public {
        (VestingClaimRecipient vesting, BaseClaimRecipientHarness pinned) =
            _deployVesting(uint128(FEES_0), uint128(FEES_1));
        _startVesting(vesting, FEES_0, 0);

        vm.roll(block.number + 1);
        vesting.claim(TOKEN_ID, 0, 0);

        assertEq(currency0.balanceOf(address(pinned)), FEES_0);
        assertEq(currency1.balanceOf(address(pinned)), 0);
        assertEq(vesting.lastClaimed(TOKEN_ID), block.number);
    }

    function test_Vesting_claim_WhenOnlyCurrency1IsAvailable_ReleasesCurrency1() public {
        (VestingClaimRecipient vesting, BaseClaimRecipientHarness pinned) =
            _deployVesting(uint128(FEES_0), uint128(FEES_1));
        _startVesting(vesting, 0, FEES_1);

        vm.roll(block.number + 1);
        vesting.claim(TOKEN_ID, 0, 0);

        assertEq(currency0.balanceOf(address(pinned)), 0);
        assertEq(currency1.balanceOf(address(pinned)), FEES_1);
        assertEq(vesting.lastClaimed(TOKEN_ID), block.number);
    }

    function test_Vesting_constructor_WhenCurrency0MaximumIsZero_Reverts(uint128 max1) public {
        max1 = uint128(bound(max1, 1, type(uint128).max));
        BaseClaimRecipientHarness pinned = new BaseClaimRecipientHarness(IPositionManager(address(manager)));

        vm.expectRevert(VestingClaimRecipient.MaxCurrencyAmountsCannotBeZero.selector);
        new VestingClaimRecipient(IPositionManager(address(manager)), 0, max1, pinned, _vestingAllowlist());
    }

    function test_Vesting_constructor_WhenCurrency1MaximumIsZero_Reverts(uint128 max0) public {
        max0 = uint128(bound(max0, 1, type(uint128).max));
        BaseClaimRecipientHarness pinned = new BaseClaimRecipientHarness(IPositionManager(address(manager)));

        vm.expectRevert(VestingClaimRecipient.MaxCurrencyAmountsCannotBeZero.selector);
        new VestingClaimRecipient(IPositionManager(address(manager)), max0, 0, pinned, _vestingAllowlist());
    }

    function test_Vesting_claim_WhenCallerIsNotRecipient_StillPaysPinnedRecipient() public {
        (VestingClaimRecipient vesting, BaseClaimRecipientHarness pinned) =
            _deployVesting(uint128(FEES_0), uint128(FEES_1));
        _startVesting(vesting, FEES_0, FEES_1);

        vm.roll(block.number + 1);
        vm.prank(stranger);
        vesting.claim(TOKEN_ID, 0, 0);

        assertEq(currency0.balanceOf(address(pinned)), FEES_0);
        assertEq(currency1.balanceOf(address(pinned)), FEES_1);
        assertEq(currency0.balanceOf(stranger), 0);
        assertEq(currency1.balanceOf(stranger), 0);
    }

    function test_Vesting_constructor_WhenRecipientUsesADifferentPositionManager_Reverts() public {
        // every release notifies the pinned recipient with this contract's token ID, so a recipient on
        // another manager would attribute releases to an unrelated position
        BaseClaimRecipientHarness foreign =
            new BaseClaimRecipientHarness(IPositionManager(address(new MockPositionManager())));

        vm.expectRevert(abi.encodeWithSelector(VestingClaimRecipient.InvalidRecipient.selector, foreign));
        new VestingClaimRecipient(
            IPositionManager(address(manager)), uint128(FEES_0), uint128(FEES_1), foreign, _vestingAllowlist()
        );
    }

    function test_Vesting_claim_WhenRecipientNotificationReverts_RollsBackClaim() public {
        RevertingNotificationRecipient rejecting =
            new RevertingNotificationRecipient(IPositionManager(address(manager)));
        VestingClaimRecipient vesting = new VestingClaimRecipient(
            IPositionManager(address(manager)),
            uint128(FEES_0),
            uint128(FEES_1),
            IClaimableRecipient(address(rejecting)),
            _vestingAllowlist()
        );
        _startVesting(vesting, FEES_0, FEES_1);
        uint256 startBlock = vesting.lastClaimed(TOKEN_ID);
        vm.roll(block.number + 1);

        vm.expectRevert(RevertingNotificationRecipient.NotificationRejected.selector);
        vesting.claim(TOKEN_ID, 0, 0);

        assertEq(currency0.balanceOf(address(rejecting)), 0);
        assertEq(currency1.balanceOf(address(rejecting)), 0);
        assertEq(vesting.lastClaimed(TOKEN_ID), startBlock);
        (uint256 amounts0, uint256 amounts1) = vesting.amounts(TOKEN_ID);
        assertEq(amounts0, FEES_0);
        assertEq(amounts1, FEES_1);
    }

    function test_Vesting_claim_WhenPositionDoesNotExist_Reverts() public {
        (VestingClaimRecipient vesting,) = _deployVesting(1 ether, 1 ether);
        uint256 invalidTokenId = TOKEN_ID + 1;

        vm.expectRevert(abi.encodeWithSelector(IClaimableRecipient.InvalidPosition.selector, invalidTokenId));
        vesting.claim(invalidTokenId, 0, 0);
    }

    function _vestingAllowlist() internal view returns (IBeneficiaryVault[] memory allowlist) {
        allowlist = new IBeneficiaryVault[](1);
        allowlist[0] = vestingVault;
    }

    function _startVesting(VestingClaimRecipient vesting, uint256 amount0, uint256 amount1) internal {
        manager.setPositionOwner(address(this));
        vestingVault.registerBeneficiary(TOKEN_ID, address(vesting));
        _notifyAmounts(vestingVault, poolKey, amount0, amount1);
        vesting.claimFrom(vestingVault, TOKEN_ID, 0, 0);
    }

    function _deployVesting(uint128 maxCurrency0PerBlock, uint128 maxCurrency1PerBlock)
        internal
        returns (VestingClaimRecipient vesting, BaseClaimRecipientHarness pinned)
    {
        pinned = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        vesting = new VestingClaimRecipient(
            IPositionManager(address(manager)), maxCurrency0PerBlock, maxCurrency1PerBlock, pinned, _vestingAllowlist()
        );
    }

    function _deployBeneficiaryVault() internal returns (BeneficiaryVault) {
        manager.setPositionOwner(address(this));
        return new BeneficiaryVault(IPositionManager(address(manager)), NATIVE_FALLBACK, TOKEN_FALLBACK);
    }

    function _deployUerc20Vault() internal returns (UERC20BeneficiaryVault) {
        return new UERC20BeneficiaryVault(IPositionManager(address(manager)), NATIVE_FALLBACK, TOKEN_FALLBACK);
    }

    function _configureUerc20Pool(PoolKey memory key, uint256 fee0, uint256 fee1) internal {
        manager.configure(key, TOKEN_ID, fee0, fee1, INITIAL_LIQUIDITY, 1 ether);
        if (key.currency0.isAddressZero()) {
            vm.deal(address(manager), fee0);
        } else {
            IERC20(Currency.unwrap(key.currency0)).transfer(address(manager), fee0);
        }
        IERC20(Currency.unwrap(key.currency1)).transfer(address(manager), fee1);
    }

    function _notifyVault(UERC20BeneficiaryVault vault, PoolKey memory key, uint256 amount0, uint256 amount1) internal {
        if (key.currency0.isAddressZero()) {
            vm.deal(address(vault), address(vault).balance + amount0);
        } else {
            IERC20(Currency.unwrap(key.currency0)).transfer(address(vault), amount0);
        }
        IERC20(Currency.unwrap(key.currency1)).transfer(address(vault), amount1);
        vault.onAmountsReceived(TOKEN_ID, amount0, amount1);
    }

    function _nativeUerc20Pool(address tokenCreator) internal returns (PoolKey memory key, MockUERC20 token) {
        token = new MockUERC20("Launch", "LAUNCH", 1_000_000 ether, address(this), tokenCreator);
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        _configureUerc20Pool(key, FEES_0, FEES_1);
    }

    function _nativePlainPool() internal returns (PoolKey memory key, MockERC20 token) {
        token = new MockERC20("Plain", "PLAIN", 1_000_000 ether, address(this));
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        _configureUerc20Pool(key, FEES_0, FEES_1);
    }

    function _tokenPairWithLaunchToken(address tokenCreator)
        internal
        returns (PoolKey memory key, MockUERC20 launchToken, MockERC20 other)
    {
        launchToken = new MockUERC20("Launch", "LAUNCH", 1_000_000 ether, address(this), tokenCreator);
        other = new MockERC20("Other", "OTHER", 1_000_000 ether, address(this));
        while (address(launchToken) > address(other)) {
            launchToken = new MockUERC20("Launch", "LAUNCH", 1_000_000 ether, address(this), tokenCreator);
        }
        key = PoolKey(Currency.wrap(address(launchToken)), Currency.wrap(address(other)), 3000, 60, IHooks(address(0)));
        _configureUerc20Pool(key, FEES_0, FEES_1);
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
        vm.expectEmit(address(recipient));
        emit IClaimableRecipient.AmountsReceived(TOKEN_ID, amount0, amount1);
        recipient.onAmountsReceived(TOKEN_ID, amount0, amount1);
    }
}
