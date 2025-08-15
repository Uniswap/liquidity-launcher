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
import {HookAddressHelper} from "../mocks/HookAddressHelper.sol";
import {TokenLauncher} from "../../src/TokenLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ILBPStrategyBasic} from "../../src/interfaces/ILBPStrategyBasic.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

contract LBPStrategyBasicTest is Test {
    event InitialPriceSet(uint160 sqrtPriceX96, uint256 tokenAmount, uint256 currencyAmount);
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 constant TOTAL_SUPPLY = 1_000e18;
    uint256 constant TOKEN_SPLIT = 5000;

    LBPStrategyBasic lbp;
    TokenLauncher tokenLauncher;
    LBPStrategyBasicNoValidation impl;
    MockERC20 token;
    MockDistributionStrategy mock;
    MigratorParameters migratorParams;

    uint256 nextTokenId;

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_URL"), 23097193);
        mock = new MockDistributionStrategy();
        tokenLauncher = new TokenLauncher(IAllowanceTransfer(PERMIT2));
        // deploy the token and give the total supply to the token launcher
        token = new MockERC20("Test Token", "TEST", TOTAL_SUPPLY, address(tokenLauncher));

        nextTokenId = IPositionManager(POSITION_MANAGER).nextTokenId();

        // give 1_000 DAI to this address
        deal(DAI, address(this), 1_000e18);

        // Initialize migratorParams now that mock is deployed
        migratorParams = MigratorParameters({
            currency: address(0),
            fee: 500,
            positionManager: POSITION_MANAGER,
            tickSpacing: 1,
            poolManager: POOL_MANAGER,
            tokenSplitToAuction: 5000,
            auctionFactory: address(mock),
            positionRecipient: address(3),
            migrationBlock: uint64(block.number + 1_000)
        });

        // Get the hook address with BEFORE_INITIALIZE permission
        address hookAddress = HookAddressHelper.getHookAddress(Hooks.BEFORE_INITIALIZE_FLAG);

        // set the address of the lbp
        lbp = LBPStrategyBasic(hookAddress);

        // Deploy the contract without address validation. This is because it validates the address in the constructor which is not set yet
        impl = new LBPStrategyBasicNoValidation(address(token), TOTAL_SUPPLY, migratorParams, bytes(""));

        // Set up the hook contract at the correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);
    }

    function test_setUpProperly() public view {
        assertEq(lbp.tokenAddress(), address(token));
        assertEq(lbp.currency(), address(0));
        assertEq(lbp.totalSupply(), TOTAL_SUPPLY);
        assertEq(address(lbp.positionManager()), POSITION_MANAGER);
        assertEq(lbp.positionRecipient(), address(3));
        assertEq(lbp.migrationBlock(), uint64(block.number + 1_000));
        assertEq(lbp.auctionFactory(), address(mock));
        assertEq(address(lbp.auction()), address(0));
        assertEq(address(lbp.poolManager()), POOL_MANAGER);

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
            TOTAL_SUPPLY,
            MigratorParameters({
                currency: address(0),
                fee: 500,
                positionManager: POSITION_MANAGER,
                tickSpacing: 100,
                poolManager: POOL_MANAGER,
                tokenSplitToAuction: 5001, // too many tokens would be sent to the auction
                auctionFactory: address(mock),
                positionRecipient: address(3),
                migrationBlock: uint64(block.number + 1_000)
            }),
            bytes("")
        );
    }

    function test_onTokenReceived_revertsWithInvalidToken() public {
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.InvalidToken.selector));
        lbp.onTokensReceived(address(0), TOTAL_SUPPLY); // token address is not the same as the token address set in the contract
    }

    function test_onTokenReceived_revertsWithIncorrectTokenSupply() public {
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.IncorrectTokenSupply.selector));
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY - 1); // token supply is not the same as the total supply set in the contract
    }

    function test_onTokenReceived_revertsWithInvalidAmountReceived() public {
        vm.prank(address(tokenLauncher));
        ERC20(token).transfer(address(lbp), TOTAL_SUPPLY - 1); // incorrect amount of tokens were transferred to the contract
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.InvalidAmountReceived.selector));
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);
    }

    function test_onTokenReceived_succeeds() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY); // transfer all the tokens from the token launcher contract to the lbp contract
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);

        // verify auction is created and set
        assertNotEq(address(lbp.auction()), address(0));
        // Verify half of the tokens are in the auction and half are in the LBP
        assertEq(token.balanceOf(address(lbp.auction())), TOTAL_SUPPLY * 5000 / 1_0000); // half of the tokens are in the auction
        assertEq(token.balanceOf(address(lbp)), TOTAL_SUPPLY * 5000 / 1_0000); // half of the tokens are in the LBP
    }

    function test_onTokensReceived_gas() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);
        vm.snapshotGasLastCall("onTokensReceived");
    }

    function test_setInitialPrice_revertsWithOnlyAuctionCanSetPrice() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.OnlyAuctionCanSetPrice.selector));
        lbp.setInitialPrice(TickMath.MIN_SQRT_PRICE, TOTAL_SUPPLY, TOTAL_SUPPLY);
    }

    function test_setInitialPrice_revertsWithInvalidCurrencyAmount() public {
        vm.deal(address(lbp.auction()), TOTAL_SUPPLY); // auction has tokens
        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidCurrencyAmount.selector));
        lbp.setInitialPrice{value: TOTAL_SUPPLY - 1}(TickMath.MIN_SQRT_PRICE, TOTAL_SUPPLY, TOTAL_SUPPLY); // incorrect amount of ETH is transferred
    }

    function test_setInitialPrice_succeeds() public {
        vm.deal(address(lbp.auction()), TOTAL_SUPPLY); // auction has tokens
        vm.prank(address(lbp.auction()));

        vm.expectEmit(false, false, false, true);
        emit InitialPriceSet(TickMath.MIN_SQRT_PRICE, TOTAL_SUPPLY, 1e18);
        lbp.setInitialPrice{value: 1e18}(TickMath.MIN_SQRT_PRICE, TOTAL_SUPPLY, 1e18);

        // Verify the pool was initialized
        assertEq(lbp.initialSqrtPriceX96(), TickMath.MIN_SQRT_PRICE);
        assertEq(lbp.initialTokenAmount(), TOTAL_SUPPLY);
        assertEq(lbp.initialCurrencyAmount(), 1e18);
        assertEq(address(lbp).balance, 1e18);
    }

    function test_setInitialPrice_gas() public {
        vm.deal(address(lbp.auction()), TOTAL_SUPPLY); // auction has tokens
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 1e18}(TickMath.MIN_SQRT_PRICE, TOTAL_SUPPLY, 1e18);
        vm.snapshotGasLastCall("setInitialPriceWithETH");
    }

    function test_setInitialPrice_revertsWithNonETHCurrencyCannotReceiveETH() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            MigratorParameters({
                currency: DAI,
                fee: 500,
                positionManager: POSITION_MANAGER,
                tickSpacing: 100,
                poolManager: POOL_MANAGER,
                tokenSplitToAuction: 5000,
                auctionFactory: address(mock),
                positionRecipient: address(3),
                migrationBlock: uint64(block.number + 1_000)
            }),
            bytes("")
        );

        // First, we need to initialize the auction by sending tokens to the LBP
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);

        // give the auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        // Give the auction contract some ETH so it can attempt to send it (which should fail)
        vm.deal(address(lbp.auction()), 1e18);

        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.NonETHCurrencyCannotReceiveETH.selector));
        lbp.setInitialPrice{value: 1e18}(TickMath.MIN_SQRT_PRICE, TOTAL_SUPPLY, 1e18); // attempts to send ETH when DAI is set as the currency
    }

    function test_setInitialPrice_withNonETHCurrency_succeeds() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            MigratorParameters({
                currency: DAI,
                fee: 500,
                positionManager: POSITION_MANAGER,
                tickSpacing: 100,
                poolManager: POOL_MANAGER,
                tokenSplitToAuction: 5000,
                auctionFactory: address(mock),
                positionRecipient: address(3),
                migrationBlock: uint64(block.number + 1_000)
            }),
            bytes("")
        );

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);
        vm.stopPrank();

        // give the auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), 1_000e18);

        vm.expectEmit(false, false, false, true);
        emit InitialPriceSet(TickMath.MIN_SQRT_PRICE, TOTAL_SUPPLY, TOTAL_SUPPLY);

        lbp.setInitialPrice(TickMath.MIN_SQRT_PRICE, TOTAL_SUPPLY, TOTAL_SUPPLY);
        vm.stopPrank();

        // Verify values are set correctly
        assertEq(lbp.initialSqrtPriceX96(), TickMath.MIN_SQRT_PRICE);
        assertEq(lbp.initialTokenAmount(), TOTAL_SUPPLY);
        assertEq(lbp.initialCurrencyAmount(), TOTAL_SUPPLY);

        // Verify the auction has no DAI and the LBP has all the DAI
        assertEq(ERC20(DAI).balanceOf(address(lbp.auction())), 0);
        assertEq(ERC20(DAI).balanceOf(address(lbp)), TOTAL_SUPPLY);
    }

    function test_setInitialPrice_withNonETHCurrency_gas() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            MigratorParameters({
                currency: DAI,
                fee: 500,
                positionManager: POSITION_MANAGER,
                tickSpacing: 100,
                poolManager: POOL_MANAGER,
                tokenSplitToAuction: 5000,
                auctionFactory: address(mock),
                positionRecipient: address(3),
                migrationBlock: uint64(block.number + 1_000)
            }),
            bytes("")
        );

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);
        vm.stopPrank();

        // give the auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), 1_000e18);

        lbp.setInitialPrice(TickMath.MIN_SQRT_PRICE, TOTAL_SUPPLY, TOTAL_SUPPLY);
        vm.snapshotGasLastCall("setInitialPriceWithNonETHCurrency");
    }

    function test_migrate_revertsWithMigrationNotAllowed() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.MigrationNotAllowed.selector)); // migration block is not reached
        lbp.migrate();
    }

    function test_migrate_succeeds() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);

        // give the auction ETH
        deal(address(lbp.auction()), 500e18);

        // set the initial price
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 500e18}(TickMath.getSqrtPriceAtTick(0), TOTAL_SUPPLY / 2, 500e18);

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        vm.prank(address(lbp));
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = lbp.key();
        vm.expectEmit(true, false, false, true);
        emit Migrated(
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks}),
            TickMath.getSqrtPriceAtTick(0)
        );
        lbp.migrate();

        // verify the pool was initialized
        assertEq(lbp.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(0));
        assertEq(lbp.initialTokenAmount(), TOTAL_SUPPLY / 2);
        assertEq(lbp.initialCurrencyAmount(), 500e18);
        assertEq(address(lbp).balance, 0);

        (PoolKey memory poolKey, PositionInfo info) =
            IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId);
        assertEq(Currency.unwrap(poolKey.currency0), address(0));
        assertEq(Currency.unwrap(poolKey.currency1), address(token));
        assertEq(poolKey.fee, 500);
        assertEq(poolKey.tickSpacing, 1);
        assertEq(info.tickLower(), TickMath.MIN_TICK);
        assertEq(info.tickUpper(), TickMath.MAX_TICK);
    }

    function test_migrate_withOneSidedPosition_succeeds() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY); // send all tokens to the LBP
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);

        uint256 ethAmt = 500e18;
        deal(address(lbp.auction()), ethAmt); // give the auction ETH
        uint256 tokenAmt = lbp.reserveSupply() / 2;
        // price is token / eth
        uint256 priceX192 = FullMath.mulDiv(tokenAmt, 2 ** 192, ethAmt);
        uint256 sqrtPriceX192 = sqrt(priceX192);
        uint160 sqrtPriceX96 = uint160(sqrtPriceX192);

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: ethAmt}(sqrtPriceX96, tokenAmt, ethAmt);

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        vm.prank(address(lbp));
        lbp.migrate();

        // assert auction has no ETH
        assertEq(address(lbp.auction()).balance, 0);

        // assert position was created at the correct token id
        (PoolKey memory poolKey, PositionInfo info) =
            IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId);
        assertEq(Currency.unwrap(poolKey.currency0), address(0));
        assertEq(Currency.unwrap(poolKey.currency1), address(token));
        assertEq(poolKey.fee, 500);
        assertEq(poolKey.tickSpacing, 1);
        assertEq(info.tickLower(), TickMath.MIN_TICK);
        assertEq(info.tickUpper(), TickMath.MAX_TICK);

        // assert one sided position was created at the correct token id
        (PoolKey memory poolKey2, PositionInfo info2) =
            IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId + 1);
        assertEq(Currency.unwrap(poolKey2.currency0), address(0));
        assertEq(Currency.unwrap(poolKey2.currency1), address(token));
        assertEq(poolKey2.fee, 500);
        assertEq(poolKey2.tickSpacing, 1);
        assertEq(info2.tickLower(), TickMath.MIN_TICK);
        assertEq(info2.tickUpper(), TickMath.getTickAtSqrtPrice(sqrtPriceX96)); // upper tick is inclusive
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function test_migrate_withNonETHCurrency_succeeds() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            MigratorParameters({
                currency: DAI,
                fee: 500,
                positionManager: POSITION_MANAGER,
                tickSpacing: 1,
                poolManager: POOL_MANAGER,
                tokenSplitToAuction: 5000,
                auctionFactory: address(mock),
                positionRecipient: address(3),
                migrationBlock: uint64(block.number + 1_000)
            }),
            bytes("")
        );

        // Set up the hook contract at the correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);
        vm.stopPrank();

        // give the auction DAI
        deal(DAI, address(lbp.auction()), TOTAL_SUPPLY / 2);

        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), TOTAL_SUPPLY / 2);

        lbp.setInitialPrice(TickMath.getSqrtPriceAtTick(0), TOTAL_SUPPLY / 2, TOTAL_SUPPLY / 2);
        vm.stopPrank();

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        lbp.migrate();

        // verify the pool was initialized
        assertEq(lbp.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(0));
        assertEq(lbp.initialTokenAmount(), TOTAL_SUPPLY / 2);
        assertEq(lbp.initialCurrencyAmount(), TOTAL_SUPPLY / 2);
        assertEq(address(lbp).balance, 0);
        assertEq(ERC20(DAI).balanceOf(address(lbp.auction())), 0);
        assertEq(ERC20(DAI).balanceOf(address(lbp)), 0);
    }

    function test_migrate_withETH_gas() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);

        // give the auction ETH
        deal(address(lbp.auction()), 500e18);

        // set the initial price
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 500e18}(TickMath.getSqrtPriceAtTick(0), TOTAL_SUPPLY / 2, 500e18);

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        vm.prank(address(lbp));
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithETH");
    }

    function test_migrate_withNonETHCurrency_gas() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            MigratorParameters({
                currency: DAI,
                fee: 500,
                positionManager: POSITION_MANAGER,
                tickSpacing: 1,
                poolManager: POOL_MANAGER,
                tokenSplitToAuction: 5000,
                auctionFactory: address(mock),
                positionRecipient: address(3),
                migrationBlock: uint64(block.number + 1_000)
            }),
            bytes("")
        );

        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);
        vm.stopPrank();

        // give the auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), 1_000e18);

        lbp.setInitialPrice(TickMath.getSqrtPriceAtTick(0), TOTAL_SUPPLY / 2, TOTAL_SUPPLY / 2);
        vm.stopPrank();

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency");
    }

    function test_migrate_revertsWithAlreadyInitialized() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);

        // give the auction ETH
        deal(address(lbp.auction()), 500e18);

        // set the initial price
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 500e18}(TickMath.getSqrtPriceAtTick(0), TOTAL_SUPPLY / 2, 500e18);

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        vm.prank(address(lbp));
        lbp.migrate();

        // give the auction more tokens for test purposes
        deal(address(token), address(lbp), TOTAL_SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(Pool.PoolAlreadyInitialized.selector)); // pool is already initialized. Cannot migrate again
        lbp.migrate();
    }

    function test_migrate_revertsWithInvalidSqrtPrice() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived(address(token), TOTAL_SUPPLY);

        vm.roll(lbp.migrationBlock()); // fast forward to the migration block
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, 0)); // invalid sqrt price
        // setInitialPrice was never called by the auction
        lbp.migrate();
    }
}
