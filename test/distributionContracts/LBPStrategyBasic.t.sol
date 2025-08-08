// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LBPStrategyBasic} from "../../src/distributionContracts/LBPStrategyBasic.sol";
import {MigratorParameters} from "../../src/distributionContracts/LBPStrategyBasic.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {MockDistributionStrategy} from "../mocks/MockDistributionStrategy.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LBPStrategyBasicNoValidation} from "../mocks/LBPStrategyBasicNoValidation.sol";
import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";
import {TokenLauncher} from "../../src/TokenLauncher.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ILBPStrategyBasic} from "../../src/interfaces/ILBPStrategyBasic.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract LBPStrategyBasicTest is Test, DeployPermit2 {
    event InitialPriceSet(uint160 sqrtPriceX96, uint256 tokenAmount, uint256 currencyAmount);
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    LBPStrategyBasicNoValidation lbp;
    address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    TokenLauncher tokenLauncher;

    MockERC20 token;
    MockDistributionStrategy mock;
    uint256 totalSupply = 1000e18;

    // Create a mock position manager address
    address positionManager = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    LBPStrategyBasicNoValidation impl;

    uint160 constant hookPermissionCount = 14;
    uint160 constant clearAllHookPermissionsMask = ~uint160(0) << (hookPermissionCount);

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_URL"), 23097193);
        mock = new MockDistributionStrategy();
        tokenLauncher = new TokenLauncher(IAllowanceTransfer(permit2));
        token = new MockERC20("Test Token", "TEST", totalSupply, address(tokenLauncher));

        deal(address(token), address(tokenLauncher), totalSupply);
        deal(DAI, address(this), totalSupply);

        lbp = LBPStrategyBasicNoValidation(
            address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | Hooks.BEFORE_INITIALIZE_FLAG))
        );

        // Deploy the contract without validation - we'll test it at its deployed address
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            abi.encode(
                MigratorParameters({
                    currency: address(0),
                    fee: 500,
                    positionManager: positionManager,
                    tickSpacing: 1,
                    poolManager: poolManager,
                    tokenSplit: 5000,
                    auctionFactory: address(mock),
                    positionRecipient: address(this),
                    migrationBlock: uint64(block.number + 1000)
                }),
                bytes("")
            )
        );

        vm.etch(address(lbp), address(impl).code);

        // Copy all storage slots (0-10 should cover everything)
        bytes32 value;
        for (uint256 i = 0; i < 10; i++) {
            value = vm.load(address(impl), bytes32(i));
            vm.store(address(lbp), bytes32(i), value);
        }

        // Update the hooks address in the PoolKey (stored in slot 7)
        // The hooks address is stored in the lower 20 bytes of slot 7
        bytes32 slot7 = vm.load(address(lbp), bytes32(uint256(7)));
        // Clear the lower 20 bytes and set the new hooks address
        bytes32 updatedSlot7 =
            (slot7 & bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFF) << 160)) | bytes32(uint256(uint160(address(lbp))));
        vm.store(address(lbp), bytes32(uint256(7)), updatedSlot7);
    }

    function test_setUpProperly() public view {
        assertEq(lbp.tokenAddress(), address(token));
        assertEq(lbp.currency(), address(0));
        assertEq(lbp.totalSupply(), 1000e18);
        assertEq(address(lbp.positionManager()), positionManager);
        assertEq(lbp.positionRecipient(), address(this));
        assertEq(lbp.migrationBlock(), uint64(block.number + 1000));
        assertEq(lbp.auctionFactory(), address(mock));
        assertEq(lbp.tokenSplit(), 5000);
        assertEq(lbp.auction(), address(0));

        // Get the pool key components from the contract
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = lbp.key();

        // Test pool key properties
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token));
        assertEq(fee, 500);
        assertEq(tickSpacing, 1);
        assertEq(address(hooks), address(lbp));
    }

    function test_setUp_revertsWithTokenSplitTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.TokenSplitTooHigh.selector));
        new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            abi.encode(
                MigratorParameters({
                    currency: address(0),
                    fee: 500,
                    positionManager: positionManager,
                    tickSpacing: 100,
                    poolManager: poolManager,
                    tokenSplit: 5001,
                    auctionFactory: address(mock),
                    positionRecipient: address(this),
                    migrationBlock: uint64(block.number + 1000)
                }),
                bytes("")
            )
        );
    }

    function test_onTokenReceived_revertsWithInvalidToken() public {
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.InvalidToken.selector));
        lbp.onTokensReceived(address(0), totalSupply);
    }

    function test_onTokenReceived_revertsWithIncorrectTokenSupply() public {
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.IncorrectTokenSupply.selector));
        lbp.onTokensReceived(address(token), totalSupply - 1);
    }

    function test_onTokenReceived_revertsWithInvalidAmountReceived() public {
        vm.prank(address(tokenLauncher));
        ERC20(token).transfer(address(lbp), totalSupply - 1);
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.InvalidAmountReceived.selector));
        lbp.onTokensReceived(address(token), totalSupply);
    }

    function test_onTokenReceived_succeeds() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);

        // verify auction is created and set
        assertNotEq(lbp.auction(), address(0));
        // Verify half of the tokens are in the auction and half are in the LBP
        assertEq(token.balanceOf(address(lbp.auction())), totalSupply / 2);
        assertEq(token.balanceOf(address(lbp)), totalSupply / 2);
    }

    function test_onTokensReceived_gas() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);
        vm.snapshotGasLastCall("onTokensReceived");
    }

    function test_setInitialPrice_revertsWithOnlyAuctionCanSetPrice() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.OnlyAuctionCanSetPrice.selector));
        lbp.setInitialPrice(TickMath.MIN_SQRT_PRICE, totalSupply, totalSupply);
    }

    function test_setInitialPrice_revertsWithInvalidCurrencyAmount() public {
        vm.deal(address(lbp.auction()), totalSupply);
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidCurrencyAmount.selector));
        lbp.setInitialPrice{value: totalSupply - 1}(TickMath.MIN_SQRT_PRICE, totalSupply, totalSupply);
    }

    function test_setInitialPrice_succeeds() public {
        vm.deal(address(lbp.auction()), totalSupply);
        vm.prank(address(lbp.auction()));

        vm.expectEmit(false, false, false, true);
        emit InitialPriceSet(TickMath.MIN_SQRT_PRICE, totalSupply, 1e18);
        lbp.setInitialPrice{value: 1e18}(TickMath.MIN_SQRT_PRICE, totalSupply, 1e18);

        // Verify the pool was initialized
        assertEq(lbp.initialSqrtPriceX96(), TickMath.MIN_SQRT_PRICE);
        assertEq(lbp.initialTokenAmount(), totalSupply);
        assertEq(lbp.initialCurrencyAmount(), 1e18);
        assertEq(address(lbp).balance, 1e18);
    }

    function test_setInitialPrice_gas() public {
        vm.deal(address(lbp.auction()), totalSupply);
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 1e18}(TickMath.MIN_SQRT_PRICE, totalSupply, 1e18);
        vm.snapshotGasLastCall("setInitialPriceWithETH");
    }

    function test_setInitialPrice_revertsWithNonETHCurrencyCannotReceiveETH() public {
        // Deploy the contract without validation - we'll test it at its deployed address
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            abi.encode(
                MigratorParameters({
                    currency: DAI,
                    fee: 500,
                    positionManager: positionManager,
                    tickSpacing: 100,
                    poolManager: poolManager,
                    tokenSplit: 5000,
                    auctionFactory: address(mock),
                    positionRecipient: address(this),
                    migrationBlock: uint64(block.number + 1000)
                }),
                bytes("")
            )
        );

        // First, we need to initialize the auction by sending tokens to the LBP
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);

        // Now the auction should be created and we can transfer DAI to it
        //DAI.transfer(lbp.auction(), DAI.balanceOf(address(this)));
        deal(DAI, lbp.auction(), 1000e18);

        // Give the auction contract some ETH so it can attempt to send it (which should fail)
        vm.deal(lbp.auction(), 1e18);

        vm.prank(lbp.auction());
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.NonETHCurrencyCannotReceiveETH.selector));
        lbp.setInitialPrice{value: 1e18}(TickMath.MIN_SQRT_PRICE, totalSupply, 1e18);
    }

    function test_setInitialPrice_withNonETHCurrency_succeeds() public {
        // Deploy the contract without validation - we'll test it at its deployed address
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            abi.encode(
                MigratorParameters({
                    currency: DAI,
                    fee: 500,
                    positionManager: positionManager,
                    tickSpacing: 100,
                    poolManager: poolManager,
                    tokenSplit: 5000,
                    auctionFactory: address(mock),
                    positionRecipient: address(this),
                    migrationBlock: uint64(block.number + 1000)
                }),
                bytes("")
            )
        );

        // First, we need to initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);
        vm.stopPrank();

        // Now the auction should be created and we can transfer DAI to it
        ERC20(DAI).transfer(lbp.auction(), totalSupply);

        vm.startPrank(lbp.auction());
        ERC20(DAI).approve(address(lbp), totalSupply);

        vm.expectEmit(false, false, false, true);
        emit InitialPriceSet(TickMath.MIN_SQRT_PRICE, totalSupply, totalSupply);

        lbp.setInitialPrice(TickMath.MIN_SQRT_PRICE, totalSupply, totalSupply);
        vm.stopPrank();

        // Verify values are set correctly
        assertEq(lbp.initialSqrtPriceX96(), TickMath.MIN_SQRT_PRICE);
        assertEq(lbp.initialTokenAmount(), totalSupply);
        assertEq(lbp.initialCurrencyAmount(), totalSupply);

        // Verify the auction has no DAI and the LBP has all the DAI
        assertEq(ERC20(DAI).balanceOf(address(lbp.auction())), 0);
        assertEq(ERC20(DAI).balanceOf(address(lbp)), totalSupply);
    }

    function test_setInitialPrice_withNonETHCurrency_gas() public {
        // Deploy the contract without validation - we'll test it at its deployed address
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            abi.encode(
                MigratorParameters({
                    currency: DAI,
                    fee: 500,
                    positionManager: positionManager,
                    tickSpacing: 100,
                    poolManager: poolManager,
                    tokenSplit: 5000,
                    auctionFactory: address(mock),
                    positionRecipient: address(this),
                    migrationBlock: uint64(block.number + 1000)
                }),
                bytes("")
            )
        );

        // First, we need to initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);
        vm.stopPrank();

        // Now the auction should be created and we can transfer DAI to it
        ERC20(DAI).transfer(lbp.auction(), totalSupply);

        vm.startPrank(lbp.auction());
        ERC20(DAI).approve(address(lbp), totalSupply);

        lbp.setInitialPrice(TickMath.MIN_SQRT_PRICE, totalSupply, totalSupply);
        vm.snapshotGasLastCall("setInitialPriceWithNonETHCurrency");
    }

    function test_migrate_revertsWithMigrationNotAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.MigrationNotAllowed.selector));
        lbp.migrate();
    }

    function test_migrate_succeeds() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);

        // permit permit2 to spend the token
        vm.startPrank(address(lbp));
        token.approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(token), address(positionManager), type(uint160).max, 0);
        vm.stopPrank();

        deal(address(lbp.auction()), 500e18);

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 500e18}(TickMath.getSqrtPriceAtTick(0), totalSupply / 2, 500e18);

        vm.roll(lbp.migrationBlock());

        vm.prank(address(lbp));
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = lbp.key();
        vm.expectEmit(true, false, false, true);
        emit Migrated(
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks}),
            TickMath.getSqrtPriceAtTick(0)
        );
        lbp.migrate();

        // Verify the pool was initialized
        assertEq(lbp.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(0));
        assertEq(lbp.initialTokenAmount(), totalSupply / 2);
        assertEq(lbp.initialCurrencyAmount(), 500e18);
        assertEq(address(lbp).balance, 0);
    }

    function test_migrate_withETH_gas() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);

        // permit permit2 to spend the token
        vm.startPrank(address(lbp));
        token.approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(token), address(positionManager), type(uint160).max, 0);
        vm.stopPrank();

        deal(address(lbp.auction()), 500e18);

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 500e18}(TickMath.getSqrtPriceAtTick(0), totalSupply / 2, 500e18);

        vm.roll(lbp.migrationBlock());

        vm.prank(address(lbp));
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithETH");
    }

    function test_migrate_withNonETHCurrency_gas() public {
        // Deploy the contract without validation - we'll test it at its deployed address
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            abi.encode(
                MigratorParameters({
                    currency: DAI,
                    fee: 500,
                    positionManager: positionManager,
                    tickSpacing: 1,
                    poolManager: poolManager,
                    tokenSplit: 5000,
                    auctionFactory: address(mock),
                    positionRecipient: address(this),
                    migrationBlock: uint64(block.number + 1000)
                }),
                bytes("")
            )
        );

        vm.etch(address(lbp), address(impl).code);

        // Copy all storage slots (0-10 should cover everything)
        bytes32 value;
        for (uint256 i = 0; i < 10; i++) {
            value = vm.load(address(impl), bytes32(i));
            vm.store(address(lbp), bytes32(i), value);
        }

        // Update the hooks address in the PoolKey (stored in slot 7)
        // The hooks address is stored in the lower 20 bytes of slot 7
        bytes32 slot7 = vm.load(address(lbp), bytes32(uint256(7)));
        // Clear the lower 20 bytes and set the new hooks address
        bytes32 updatedSlot7 =
            (slot7 & bytes32(uint256(0xFFFFFFFFFFFFFFFFFFFFFFFF) << 160)) | bytes32(uint256(uint160(address(lbp))));
        vm.store(address(lbp), bytes32(uint256(7)), updatedSlot7);

        // First, we need to initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);
        vm.stopPrank();

        // permit permit2 to spend the token and DAI
        vm.startPrank(address(lbp));
        token.approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(token), address(positionManager), type(uint160).max, 0);

        ERC20(DAI).approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(DAI), address(positionManager), type(uint160).max, 0);
        vm.stopPrank();

        // Now the auction should be created and we can transfer DAI to it
        ERC20(DAI).transfer(lbp.auction(), totalSupply);

        vm.startPrank(lbp.auction());
        ERC20(DAI).approve(address(lbp), totalSupply);

        lbp.setInitialPrice(TickMath.getSqrtPriceAtTick(0), totalSupply / 2, totalSupply / 2);
        vm.stopPrank();

        vm.roll(lbp.migrationBlock());

        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency");
    }

    function test_migrate_revertsWithAlreadyInitialized() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);

        // permit2 to spend the token
        vm.startPrank(address(lbp));
        token.approve(permit2, type(uint256).max);
        IAllowanceTransfer(permit2).approve(address(token), address(positionManager), type(uint160).max, 0);
        vm.stopPrank();

        deal(address(lbp.auction()), 500e18);

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 500e18}(TickMath.getSqrtPriceAtTick(0), totalSupply / 2, 500e18);

        vm.roll(lbp.migrationBlock());

        vm.prank(address(lbp));
        lbp.migrate();

        vm.expectRevert(abi.encodeWithSelector(Pool.PoolAlreadyInitialized.selector));
        lbp.migrate();
    }

    function test_migrate_revertsWithInvalidSqrtPrice() public {
        vm.roll(lbp.migrationBlock());
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, 0));
        // set price was never called by the auction
        lbp.migrate();
    }
}
