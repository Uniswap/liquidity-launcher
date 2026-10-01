// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {ERC721} from "solady/tokens/ERC721.sol";
import {UERC20BeneficiaryVault} from "../../src/periphery/UERC20BeneficiaryVault.sol";
import {IBeneficiaryVault} from "../../src/interfaces/IBeneficiaryVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockUERC20} from "../mocks/MockUERC20.sol";

contract UERC20BeneficiaryVaultTest is Test {
    using CurrencyLibrary for Currency;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;

    UERC20BeneficiaryVault internal vault;
    address internal quoteFallback = makeAddr("quoteFallback");
    address internal tokenFallback = makeAddr("tokenFallback");
    address internal creator = makeAddr("creator");
    address internal stranger = makeAddr("stranger");
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );
        vault = new UERC20BeneficiaryVault(POSITION_MANAGER, Currency.wrap(address(0)), quoteFallback, tokenFallback);
        vm.deal(address(this), 10_000 ether);
    }

    function _mintNativePosition(address launchToken, address owner) internal returns (uint256 tokenId) {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(launchToken),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        return _mint(key, owner, 100 ether, 100 ether, 100 ether);
    }

    function _mintTokenPairPosition(address low, address high, address owner) internal returns (uint256 tokenId) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(low),
            currency1: Currency.wrap(high),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        IERC20(low).transfer(address(POSITION_MANAGER), 100 ether);
        return _mint(key, owner, 100 ether, 100 ether, 0);
    }

    function _mint(PoolKey memory key, address owner, uint256 amount0, uint256 amount1, uint256 value)
        internal
        returns (uint256 tokenId)
    {
        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, lower, upper, liquidity, amount0, amount1, owner, bytes(""));
        params[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency0, key.currency1, address(this));
        tokenId = POSITION_MANAGER.nextTokenId();
        IERC20(Currency.unwrap(key.currency1)).transfer(address(POSITION_MANAGER), amount1);
        POSITION_MANAGER.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp);
    }

    function _credit(uint256 tokenId, uint256 nativeAmount, address token, uint256 tokenAmount) internal {
        if (nativeAmount != 0) vm.deal(address(vault), address(vault).balance + nativeAmount);
        if (tokenAmount != 0) IERC20(token).transfer(address(vault), tokenAmount);
        vault.onAmountsReceived(tokenId, nativeAmount, tokenAmount);
    }

    function _creditPair(uint256 tokenId, address token0, uint256 amount0, address token1, uint256 amount1) internal {
        if (amount0 != 0) IERC20(token0).transfer(address(vault), amount0);
        if (amount1 != 0) IERC20(token1).transfer(address(vault), amount1);
        vault.onAmountsReceived(tokenId, amount0, amount1);
    }

    function _launchToken(address tokenCreator) internal returns (MockUERC20) {
        return new MockUERC20("Launched", "LAUNCH", 1_000_000 ether, address(this), tokenCreator);
    }

    function test_claim_registeredPositionUsesBaseSemantics() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        vault.registerBeneficiary(tokenId, beneficiary);
        _credit(tokenId, 1 ether, address(token), 2 ether);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotBeneficiary.selector, tokenId, creator));
        vault.claim(tokenId, 0, 0);

        vm.prank(beneficiary);
        vault.claim(tokenId, 0, 0);
        assertEq(beneficiary.balance, 1 ether);
        assertEq(token.balanceOf(beneficiary), 2 ether);
    }

    function test_register_mintsBeneficiaryNftToCreator() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));

        vm.prank(creator);
        vault.registerBeneficiary(tokenId, creator);

        assertEq(vault.ownerOf(tokenId), creator);
    }

    function test_register_revertsForNonCreator() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UERC20BeneficiaryVault.NotAuthorized.selector, tokenId, stranger));
        vault.registerBeneficiary(tokenId, creator);
    }

    function test_register_revertsWhenAlreadyRegistered() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));

        vm.prank(creator);
        vault.registerBeneficiary(tokenId, creator);

        vm.prank(creator);
        vm.expectRevert(ERC721.TokenAlreadyExists.selector);
        vault.registerBeneficiary(tokenId, creator);
    }

    function test_claim_afterRegister_creatorReceivesBoth() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _credit(tokenId, 1 ether, address(token), 2 ether);

        vm.prank(creator);
        vault.registerBeneficiary(tokenId, creator);
        vm.prank(creator);
        vault.claim(tokenId, 0, 0);

        assertEq(creator.balance, 1 ether);
        assertEq(token.balanceOf(creator), 2 ether);
        (uint128 credited0, uint128 credited1) = vault.amounts(tokenId);
        assertEq(credited0, 0);
        assertEq(credited1, 0);
    }

    function test_claim_unregisteredCreatorAutoRegistersAndReceivesFees() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _credit(tokenId, 1 ether, address(token), 2 ether);

        vm.prank(creator);
        vault.claim(tokenId, 0, 0);

        assertEq(vault.ownerOf(tokenId), creator);
        assertEq(creator.balance, 1 ether);
        assertEq(token.balanceOf(creator), 2 ether);
        assertEq(quoteFallback.balance, 0);
        assertEq(token.balanceOf(tokenFallback), 0);
        (uint128 credited0, uint128 credited1) = vault.amounts(tokenId);
        assertEq(credited0, 0);
        assertEq(credited1, 0);
    }

    function test_claim_secondClaimRunsBasePathWithoutGraffiti() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _credit(tokenId, 1 ether, address(token), 2 ether);

        vm.prank(creator);
        vault.registerBeneficiary(tokenId, creator);
        vm.prank(creator);
        vault.claim(tokenId, 0, 0);

        token.setGraffitiReverts(true);
        _credit(tokenId, 3 ether, address(token), 4 ether);
        vm.prank(creator);
        vault.claim(tokenId, 0, 0);

        assertEq(creator.balance, 4 ether);
        assertEq(token.balanceOf(creator), 6 ether);
    }

    function test_claim_nftTransferMovesClaimRight() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _credit(tokenId, 1 ether, address(token), 2 ether);

        vm.prank(creator);
        vault.registerBeneficiary(tokenId, creator);
        vm.prank(creator);
        vault.claim(tokenId, 0, 0);

        vm.prank(creator);
        vault.transferFrom(creator, beneficiary, tokenId);
        _credit(tokenId, 3 ether, address(token), 4 ether);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotBeneficiary.selector, tokenId, creator));
        vault.claim(tokenId, 0, 0);

        vm.prank(beneficiary);
        vault.claim(tokenId, 0, 0);
        assertEq(beneficiary.balance, 3 ether);
        assertEq(token.balanceOf(beneficiary), 4 ether);
    }

    function test_register_creatorOfCurrency0() public {
        MockUERC20 launchToken = _launchToken(creator);
        MockERC20 other = new MockERC20("Other", "OTHER", 1_000_000 ether, address(this));
        while (address(launchToken) > address(other)) {
            launchToken = _launchToken(creator);
        }

        uint256 tokenId = _mintTokenPairPosition(address(launchToken), address(other), address(this));
        _creditPair(tokenId, address(launchToken), 2 ether, address(other), 3 ether);

        vm.prank(creator);
        vault.registerBeneficiary(tokenId, creator);
        vm.prank(creator);
        vault.claim(tokenId, 0, 0);

        assertEq(launchToken.balanceOf(creator), 2 ether);
        assertEq(other.balanceOf(creator), 3 ether);
    }

    function test_claim_revertsForNonCreatorAndDoesNotFlush() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _credit(tokenId, 1 ether, address(token), 2 ether);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(UERC20BeneficiaryVault.NotAuthorized.selector, tokenId, stranger));
        vault.claim(tokenId, 0, 0);

        assertEq(quoteFallback.balance, 0);
        assertEq(token.balanceOf(tokenFallback), 0);
        (uint128 credited0, uint128 credited1) = vault.amounts(tokenId);
        assertEq(credited0, 1 ether);
        assertEq(credited1, 2 ether);
    }

    function test_claim_nonLauncherTokenStillFlushes() public {
        MockERC20 token = new MockERC20("Plain", "PLAIN", 1_000_000 ether, address(this));
        uint256 tokenId = _mintNativePosition(address(token), address(this));
        _credit(tokenId, 1 ether, address(token), 2 ether);

        vm.prank(stranger);
        vault.claim(tokenId, 0, 0);

        assertEq(quoteFallback.balance, 1 ether);
        assertEq(token.balanceOf(tokenFallback), 2 ether);
    }

    function test_register_onlyNamedCreatorCanRegister() public {
        MockUERC20 token = _launchToken(stranger);
        uint256 tokenId = _mintNativePosition(address(token), address(this));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(UERC20BeneficiaryVault.NotAuthorized.selector, tokenId, creator));
        vault.registerBeneficiary(tokenId, creator);

        vm.prank(stranger);
        vault.registerBeneficiary(tokenId, stranger);
        assertEq(vault.ownerOf(tokenId), stranger);
    }

    function test_register_mintsToSpecifiedBeneficiary() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));

        vm.prank(creator);
        vault.registerBeneficiary(tokenId, beneficiary);

        assertEq(vault.ownerOf(tokenId), beneficiary);
    }

    function test_registerBeneficiary_positionOwnerCanRegisterWithoutBeingCreator() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));

        vault.registerBeneficiary(tokenId, beneficiary);

        assertEq(vault.ownerOf(tokenId), beneficiary);
    }

    function test_registerBeneficiary_positionOwnerCanRegisterNonLauncherPosition() public {
        MockERC20 token = new MockERC20("Plain", "PLAIN", 1_000_000 ether, address(this));
        uint256 tokenId = _mintNativePosition(address(token), address(this));

        vault.registerBeneficiary(tokenId, beneficiary);

        assertEq(vault.ownerOf(tokenId), beneficiary);
    }

    function test_registerBeneficiary_invalidBeneficiaryRevertsForPositionOwner() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));

        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidBeneficiary.selector, address(0)));
        vault.registerBeneficiary(tokenId, address(0));

        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidBeneficiary.selector, address(vault)));
        vault.registerBeneficiary(tokenId, address(vault));
    }

    function test_register_revertsWhenBeneficiaryIsInvalid() public {
        MockUERC20 token = _launchToken(creator);
        uint256 tokenId = _mintNativePosition(address(token), address(this));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidBeneficiary.selector, address(0)));
        vault.registerBeneficiary(tokenId, address(0));

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.InvalidBeneficiary.selector, address(vault)));
        vault.registerBeneficiary(tokenId, address(vault));
    }

    receive() external payable {}
}
