// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
import {CreatorClaimRecipient} from "../../src/periphery/CreatorClaimRecipient.sol";
import {ICreatorClaimRecipient} from "../../src/interfaces/ICreatorClaimRecipient.sol";
import {IClaimableRecipient} from "../../src/interfaces/IClaimableRecipient.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockUERC20} from "../mocks/MockUERC20.sol";

/// @dev An ERC20 without a graffiti whose fallback answers any other call with empty returndata.
contract FallbackERC20 is ERC20 {
    constructor(uint256 initialSupply, address recipient) ERC20("Fallback", "FALL") {
        _mint(recipient, initialSupply);
    }

    fallback() external {}
}

contract CreatorClaimRecipientTest is Test {
    using CurrencyLibrary for Currency;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;

    CreatorClaimRecipient internal recipient;
    MockUERC20 internal token;
    address internal creator = makeAddr("creator");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );
        recipient = new CreatorClaimRecipient(POSITION_MANAGER);
        token = new MockUERC20("Launched", "LAUNCH", 1_000_000 ether, address(this), creator);
        vm.deal(address(this), 1_000 ether);
    }

    function _mintNativePosition(address currency1Token, address owner) internal returns (uint256 tokenId) {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(currency1Token),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        return _mintPosition(key, owner);
    }

    function _mintPosition(PoolKey memory key, address owner) internal returns (uint256 tokenId) {
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
        uint256 value = 100 ether;
        if (!key.currency0.isAddressZero()) {
            IERC20(Currency.unwrap(key.currency0)).transfer(address(POSITION_MANAGER), 100 ether);
            value = 0;
        }
        IERC20(Currency.unwrap(key.currency1)).transfer(address(POSITION_MANAGER), 100 ether);
        POSITION_MANAGER.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp);
    }

    function _creditNative(uint256 tokenId, uint256 nativeAmount) internal {
        vm.deal(address(recipient), address(recipient).balance + nativeAmount);
        recipient.onAmountsReceived(tokenId, nativeAmount, 0);
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_claim_creatorReceivesNativeAndAccountingIsZeroed() public {
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _creditNative(tokenId, 1 ether);
        vm.prank(creator);
        recipient.claim(tokenId, 1 ether, 0);
        vm.snapshotGasLastCall("CreatorClaimRecipient.claim");
        assertEq(creator.balance, 1 ether);
        (uint256 nativeAmount, uint256 tokenAmount) = recipient.amounts(tokenId);
        assertEq(nativeAmount, 0);
        assertEq(tokenAmount, 0);
        assertEq(recipient.totalAmounts(CurrencyLibrary.ADDRESS_ZERO), 0);
    }

    function test_claim_proofRerunsOnEveryClaim() public {
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _creditNative(tokenId, 1 ether);
        vm.prank(creator);
        recipient.claim(tokenId, 0, 0);
        _creditNative(tokenId, 2 ether);
        vm.prank(creator);
        recipient.claim(tokenId, 0, 0);
        assertEq(creator.balance, 3 ether);
    }

    function test_claim_nonCreatorRevertsAndAccountingIsUntouched() public {
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _creditNative(tokenId, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ICreatorClaimRecipient.NotTokenCreator.selector, tokenId, stranger));
        recipient.claim(tokenId, 0, 0);
        (uint256 nativeAmount,) = recipient.amounts(tokenId);
        assertEq(nativeAmount, 1 ether);
        assertEq(recipient.totalAmounts(CurrencyLibrary.ADDRESS_ZERO), 1 ether);
    }

    function test_claim_onlyTheRecordedCreatorCanClaim() public {
        MockUERC20 strangersToken = new MockUERC20("Launched", "LAUNCH", 1_000_000 ether, address(this), stranger);
        uint256 tokenId = _mintNativePosition(address(strangersToken), address(this));
        _creditNative(tokenId, 1 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ICreatorClaimRecipient.NotTokenCreator.selector, tokenId, creator));
        recipient.claim(tokenId, 0, 0);
        vm.prank(stranger);
        recipient.claim(tokenId, 0, 0);
        assertEq(stranger.balance, 1 ether);
    }

    function test_claim_currency1WithoutGraffitiReverts() public {
        MockERC20 plainToken = new MockERC20("Plain", "PLAIN", 1_000_000 ether, address(this));
        uint256 tokenId = _mintNativePosition(address(plainToken), address(this));
        _creditNative(tokenId, 1 ether);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ICreatorClaimRecipient.NotTokenCreator.selector, tokenId, creator));
        recipient.claim(tokenId, 0, 0);
    }

    function test_claim_currency1AnsweringWithEmptyReturndataReverts() public {
        FallbackERC20 fallbackToken = new FallbackERC20(1_000_000 ether, address(this));
        uint256 tokenId = _mintNativePosition(address(fallbackToken), address(this));
        _creditNative(tokenId, 1 ether);

        // The fallback makes graffiti() succeed with no returndata: the raw read reports "not a
        // creator" where a try/catch would surface an uncatchable decode error.
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ICreatorClaimRecipient.NotTokenCreator.selector, tokenId, creator));
        recipient.claim(tokenId, 0, 0);
    }

    function test_claim_nonNativePositionReverts() public {
        MockERC20 other = new MockERC20("Other", "OTHER", 1_000_000 ether, address(this));
        (address low, address high) =
            address(token) < address(other) ? (address(token), address(other)) : (address(other), address(token));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(low),
            currency1: Currency.wrap(high),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        uint256 tokenId = _mintPosition(key, address(this));
        IERC20(low).transfer(address(recipient), 1 ether);
        recipient.onAmountsReceived(tokenId, 1 ether, 0);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(ICreatorClaimRecipient.NotNativePosition.selector, tokenId));
        recipient.claim(tokenId, 0, 0);
    }

    function test_claim_tokenSideIsNeverPaid() public {
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        vm.deal(address(recipient), 1 ether);
        token.transfer(address(recipient), 2 ether);
        recipient.onAmountsReceived(tokenId, 1 ether, 2 ether);

        vm.prank(creator);
        recipient.claim(tokenId, 1 ether, 0);

        assertEq(creator.balance, 1 ether);
        assertEq(token.balanceOf(creator), 0);
        (uint256 nativeAmount, uint256 tokenAmount) = recipient.amounts(tokenId);
        assertEq(nativeAmount, 0);
        assertEq(tokenAmount, 2 ether);
        assertEq(recipient.totalAmounts(Currency.wrap(address(token))), 2 ether);
    }

    function test_claim_revertsWhenMinimumExceedsAvailable() public {
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _creditNative(tokenId, 1 ether);
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimableRecipient.InsufficientAmountReceived.selector,
                CurrencyLibrary.ADDRESS_ZERO,
                1 ether,
                1 ether + 1
            )
        );
        recipient.claim(tokenId, 1 ether + 1, 0);
    }

    function testFuzz_claim_paysAnyAttributedNativeAmount(uint128 nativeAmount) public {
        nativeAmount = uint128(bound(nativeAmount, 1, type(uint128).max));
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _creditNative(tokenId, nativeAmount);
        vm.prank(creator);
        recipient.claim(tokenId, nativeAmount, 0);
        assertEq(creator.balance, nativeAmount);
        (uint256 remaining,) = recipient.amounts(tokenId);
        assertEq(remaining, 0);
    }

    receive() external payable {}
}
