// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BeneficiaryVault} from "../../src/periphery/BeneficiaryVault.sol";
import {BaseLPFeesPositionRecipient} from "../../src/periphery/BaseLPFeesPositionRecipient.sol";
import {IBeneficiaryVault} from "../../src/interfaces/IBeneficiaryVault.sol";
import {ILPFeesPositionRecipient} from "../../src/interfaces/ILPFeesPositionRecipient.sol";
import {ILPFeesExecutor} from "../../src/interfaces/ILPFeesExecutor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract MockVaultExecutor is ILPFeesExecutor {
    uint256 public callbackCalls;
    uint256 public lastTokenId;
    uint256 public lastCurrency0Amount;
    uint256 public lastCurrency1Amount;

    function collect(ILPFeesPositionRecipient recipient, uint256 tokenId) external {
        recipient.collectFees(tokenId, 0, 0);
    }

    function callback(PoolKey memory, uint256 tokenId, uint256 currency0Amount, uint256 currency1Amount)
        external
        override
    {
        callbackCalls++;
        lastTokenId = tokenId;
        lastCurrency0Amount = currency0Amount;
        lastCurrency1Amount = currency1Amount;
    }

    receive() external payable {}
}

contract PartialTransferRecipient is BaseLPFeesPositionRecipient {
    constructor(IPositionManager manager) BaseLPFeesPositionRecipient(manager, address(0), type(uint256).max) {}

    function _beforeTransfer(uint256, Currency, uint256 available)
        internal
        view
        override
        returns (address recipient, uint256 sendAmount)
    {
        return (msg.sender, available / 2);
    }
}

contract ZeroTransferRecipient is BaseLPFeesPositionRecipient {
    constructor(IPositionManager manager) BaseLPFeesPositionRecipient(manager, address(0), type(uint256).max) {}

    function _beforeTransfer(uint256, Currency, uint256 available)
        internal
        pure
        override
        returns (address recipient, uint256 sendAmount)
    {
        return (address(0), available);
    }
}

contract LatePolicyRevertRecipient is BaseLPFeesPositionRecipient {
    constructor(IPositionManager manager) BaseLPFeesPositionRecipient(manager, address(0), type(uint256).max) {}

    function _beforeTransfer(uint256, Currency currency, uint256 available)
        internal
        view
        override
        returns (address recipient, uint256 sendAmount)
    {
        // Pays the native side normally but rejects the token side, so the currency1 policy
        // reverts only after the currency0 payout has already executed.
        if (currency.isAddressZero()) return (msg.sender, available);
        return (address(0), available);
    }
}

contract ReentrantVaultOwner {
    BeneficiaryVault internal immutable vault;
    uint256 internal immutable tokenId;

    constructor(BeneficiaryVault _vault, uint256 _tokenId) {
        vault = _vault;
        tokenId = _tokenId;
    }

    function collect() external {
        vault.collectFees(tokenId, 0, 0);
    }

    function callback(PoolKey memory, uint256, uint256, uint256) external {}

    receive() external payable {
        vault.onFeesReceived(tokenId, 1, 0);
    }
}

contract BeneficiaryVaultTest is Test {
    using CurrencyLibrary for Currency;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;

    BeneficiaryVault internal vault;
    MockERC20 internal token;
    address internal nativeFallback = makeAddr("nativeFallback");
    address internal tokenFallback = makeAddr("tokenFallback");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );
        vault = new BeneficiaryVault(POSITION_MANAGER, nativeFallback, tokenFallback);
        token = new MockERC20("Token", "TOKEN", 1_000_000 ether, address(this));
        vm.deal(address(this), 1_000 ether);
    }

    function _mintPosition(address owner) internal returns (uint256 tokenId) {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), 100 ether, 100 ether
        );
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, lower, upper, liquidity, 100 ether, 100 ether, owner, bytes(""));
        params[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency0, key.currency1, address(this));
        tokenId = POSITION_MANAGER.nextTokenId();
        token.transfer(address(POSITION_MANAGER), 100 ether);
        POSITION_MANAGER.modifyLiquidities{value: 100 ether}(abi.encode(actions, params), block.timestamp);
    }

    function _register(uint256 tokenId, address custodian, address owner) internal {
        vm.prank(custodian);
        vault.registerBeneficiary(tokenId, owner);
    }

    function _credit(ILPFeesPositionRecipient recipient, uint256 tokenId, uint256 nativeAmount, uint256 tokenAmount)
        internal
    {
        vm.deal(address(recipient), address(recipient).balance + nativeAmount);
        token.transfer(address(recipient), tokenAmount);
        recipient.onFeesReceived(tokenId, nativeAmount, tokenAmount);
    }

    function test_constructor_storesFallbacksAndMetadata() public view {
        assertEq(vault.nativeFallback(), nativeFallback);
        assertEq(vault.tokenFallback(), tokenFallback);
        assertEq(vault.name(), "Fee Beneficiary");
        assertEq(vault.symbol(), "FEEB");
        assertEq(vault.tokenURI(1), "");
        assertEq(vault.operator(), address(0));
        assertEq(vault.timelockBlockNumber(), type(uint256).max);
    }

    function test_constructor_revertsOnInvalidNativeFallback() public {
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidFallback.selector, address(0)));
        new BeneficiaryVault(POSITION_MANAGER, address(0), tokenFallback);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidFallback.selector, predicted));
        new BeneficiaryVault(POSITION_MANAGER, predicted, tokenFallback);
    }

    function test_constructor_revertsOnInvalidTokenFallback() public {
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidFallback.selector, address(0)));
        new BeneficiaryVault(POSITION_MANAGER, nativeFallback, address(0));
    }

    function test_registerBeneficiary_requiresCustodyAndMints() public {
        address custodian = makeAddr("custodian");
        uint256 tokenId = _mintPosition(custodian);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotPositionOwner.selector, tokenId, address(this)));
        vault.registerBeneficiary(tokenId, beneficiary);
        _register(tokenId, custodian, beneficiary);
        assertEq(vault.ownerOf(tokenId), beneficiary);
        assertEq(vault.balanceOf(beneficiary), 1);
    }

    function test_registerBeneficiary_revertsWhenBeneficiaryIsVault() public {
        uint256 tokenId = _mintPosition(address(this));
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidBeneficiary.selector, address(vault)));
        vault.registerBeneficiary(tokenId, address(vault));
    }

    function test_registerBeneficiary_zeroBeneficiaryReverts() public {
        uint256 tokenId = _mintPosition(address(this));
        vm.expectRevert();
        vault.registerBeneficiary(tokenId, address(0));
    }

    function test_registerBeneficiary_currentCustodianOverridesStaleRegistration() public {
        uint256 tokenId = _mintPosition(address(this));
        address stale = makeAddr("stale");
        _register(tokenId, address(this), stale);
        address custodian = makeAddr("custodian");
        IERC721(address(POSITION_MANAGER)).transferFrom(address(this), custodian, tokenId);
        _register(tokenId, custodian, beneficiary);
        assertEq(vault.ownerOf(tokenId), beneficiary);
        assertEq(vault.balanceOf(stale), 0);
        assertEq(vault.balanceOf(beneficiary), 1);
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_onFeesReceived_enforcesBalanceProofThenCreditsBothAmounts() public {
        uint256 tokenId = _mintPosition(address(this));
        _register(tokenId, address(this), beneficiary);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILPFeesPositionRecipient.InsufficientAmountReceived.selector, CurrencyLibrary.ADDRESS_ZERO, 0, 1 ether
            )
        );
        vault.onFeesReceived(tokenId, 1 ether, 2 ether);
        vm.deal(address(vault), 1 ether);
        token.transfer(address(vault), 2 ether);
        vault.onFeesReceived(tokenId, 1 ether, 2 ether);
        vm.snapshotGasLastCall("BeneficiaryVault.onFeesReceived");
        (uint256 nativeFees, uint256 tokenFees) = vault.fees(tokenId);
        assertEq(nativeFees, 1 ether);
        assertEq(tokenFees, 2 ether);
        assertEq(vault.totalFees(CurrencyLibrary.ADDRESS_ZERO), 1 ether);
        assertEq(vault.totalFees(Currency.wrap(address(token))), 2 ether);
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_collectFees_eoaOwnerReceivesBothAndAccountingIsZeroed() public {
        uint256 tokenId = _mintPosition(address(this));
        address owner = makeAddr("owner");
        _register(tokenId, address(this), owner);
        _credit(vault, tokenId, 1 ether, 2 ether);
        vm.prank(owner);
        vault.collectFees(tokenId, 1 ether, 2 ether);
        vm.snapshotGasLastCall("BeneficiaryVault.collectFees");
        assertEq(owner.balance, 1 ether);
        assertEq(token.balanceOf(owner), 2 ether);
        (uint256 nativeFees, uint256 tokenFees) = vault.fees(tokenId);
        assertEq(nativeFees, 0);
        assertEq(tokenFees, 0);
        assertEq(vault.totalFees(CurrencyLibrary.ADDRESS_ZERO), 0);
        assertEq(vault.totalFees(Currency.wrap(address(token))), 0);
    }

    function test_collectFees_nonOwnerReverts() public {
        uint256 tokenId = _mintPosition(address(this));
        _register(tokenId, address(this), beneficiary);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotBeneficiary.selector, tokenId, address(this)));
        vault.collectFees(tokenId, 0, 0);
    }

    function test_collectFees_unregisteredPositionFlushesBothFallbacksPermissionlessly() public {
        uint256 tokenId = _mintPosition(address(this));
        _credit(vault, tokenId, 1 ether, 2 ether);
        vm.prank(makeAddr("anyone"));
        vault.collectFees(tokenId, 0, 0);
        assertEq(nativeFallback.balance, 1 ether);
        assertEq(token.balanceOf(tokenFallback), 2 ether);
        assertEq(vault.totalFees(CurrencyLibrary.ADDRESS_ZERO), 0);
        assertEq(vault.totalFees(Currency.wrap(address(token))), 0);
        (uint256 nativeFees, uint256 tokenFees) = vault.fees(tokenId);
        assertEq(nativeFees, 0);
        assertEq(tokenFees, 0);
    }

    function test_collectFees_nftTransferMovesClaimRight() public {
        uint256 tokenId = _mintPosition(address(this));
        _register(tokenId, address(this), beneficiary);
        _credit(vault, tokenId, 1 ether, 2 ether);
        address newOwner = makeAddr("newOwner");
        vm.prank(beneficiary);
        vault.transferFrom(beneficiary, newOwner, tokenId);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotBeneficiary.selector, tokenId, beneficiary));
        vault.collectFees(tokenId, 0, 0);
        vm.prank(newOwner);
        vault.collectFees(tokenId, 0, 0);
        assertEq(newOwner.balance, 1 ether);
        assertEq(token.balanceOf(newOwner), 2 ether);
    }

    function test_collectFees_contractOwnerGetsCallbackWithActualAmounts() public {
        uint256 tokenId = _mintPosition(address(this));
        MockVaultExecutor executor = new MockVaultExecutor();
        _register(tokenId, address(this), address(executor));
        _credit(vault, tokenId, 1 ether, 2 ether);
        executor.collect(vault, tokenId);
        assertEq(executor.callbackCalls(), 1);
        assertEq(executor.lastTokenId(), tokenId);
        assertEq(executor.lastCurrency0Amount(), 1 ether);
        assertEq(executor.lastCurrency1Amount(), 2 ether);
        assertEq(address(executor).balance, 1 ether);
        assertEq(token.balanceOf(address(executor)), 2 ether);
    }

    function test_collectFees_partialPolicyLeavesRemainderClaimableAndAccountingConsistent() public {
        uint256 tokenId = _mintPosition(address(this));
        PartialTransferRecipient recipient = new PartialTransferRecipient(POSITION_MANAGER);
        _credit(recipient, tokenId, 8 ether, 16 ether);
        address collector = makeAddr("collector");
        vm.prank(collector);
        recipient.collectFees(tokenId, 8 ether, 16 ether);
        assertEq(collector.balance, 4 ether);
        assertEq(token.balanceOf(collector), 8 ether);
        (uint256 nativeFees, uint256 tokenFees) = recipient.fees(tokenId);
        assertEq(nativeFees, 4 ether);
        assertEq(tokenFees, 8 ether);
        assertEq(recipient.totalFees(CurrencyLibrary.ADDRESS_ZERO), 4 ether);
        assertEq(recipient.totalFees(Currency.wrap(address(token))), 8 ether);
        vm.prank(collector);
        recipient.collectFees(tokenId, 0, 0);
        assertEq(collector.balance, 6 ether);
        assertEq(token.balanceOf(collector), 12 ether);
        (nativeFees, tokenFees) = recipient.fees(tokenId);
        assertEq(nativeFees, 2 ether);
        assertEq(tokenFees, 4 ether);
    }

    function test_collectFees_latePolicyRevertUnwindsEarlierPayout() public {
        uint256 tokenId = _mintPosition(address(this));
        LatePolicyRevertRecipient recipient = new LatePolicyRevertRecipient(POSITION_MANAGER);
        _credit(recipient, tokenId, 1 ether, 2 ether);
        address collector = makeAddr("collector");
        uint256 balanceBefore = collector.balance;

        // The currency1 policy rejects after the currency0 payout already ran; the revert must
        // unwind the whole claim, native payout included.
        vm.prank(collector);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILPFeesPositionRecipient.InvalidTransferRecipient.selector, Currency.wrap(address(token))
            )
        );
        recipient.collectFees(tokenId, 0, 0);

        assertEq(collector.balance, balanceBefore);
        (uint256 nativeFees, uint256 tokenFees) = recipient.fees(tokenId);
        assertEq(nativeFees, 1 ether);
        assertEq(tokenFees, 2 ether);
    }

    function test_collectFees_zeroRecipientPolicyReverts() public {
        uint256 tokenId = _mintPosition(address(this));
        ZeroTransferRecipient recipient = new ZeroTransferRecipient(POSITION_MANAGER);
        _credit(recipient, tokenId, 1 ether, 2 ether);
        vm.prank(makeAddr("collector"));
        vm.expectRevert(
            abi.encodeWithSelector(
                ILPFeesPositionRecipient.InvalidTransferRecipient.selector, CurrencyLibrary.ADDRESS_ZERO
            )
        );
        recipient.collectFees(tokenId, 0, 0);
    }

    function test_collectFees_revertsWhenMinimumExceedsAvailable() public {
        uint256 tokenId = _mintPosition(address(this));
        _register(tokenId, address(this), beneficiary);
        _credit(vault, tokenId, 1 ether, 2 ether);
        vm.prank(beneficiary);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILPFeesPositionRecipient.InsufficientAmountReceived.selector,
                CurrencyLibrary.ADDRESS_ZERO,
                1 ether,
                1 ether + 1
            )
        );
        vault.collectFees(tokenId, 1 ether + 1, 0);
    }

    function test_collectFees_cannotAttributeInFlightPayoutFunds() public {
        uint256 tokenId = _mintPosition(address(this));
        ReentrantVaultOwner owner = new ReentrantVaultOwner(vault, tokenId);
        _register(tokenId, address(this), address(owner));
        _credit(vault, tokenId, 1 ether, 0);
        vm.expectRevert();
        owner.collect();
        (uint256 nativeFees,) = vault.fees(tokenId);
        assertEq(nativeFees, 1 ether);
    }

    receive() external payable {}
}
