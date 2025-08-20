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
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ISubscriber} from "../../src/interfaces/ISubscriber.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {console2} from "forge-std/console2.sol";

contract LBPStrategyBasicTest is Test {
    event InitialPriceSet(uint160 sqrtPriceX96, uint256 tokenAmount, uint256 currencyAmount);
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Default value for non-fuzzed tests
    uint128 constant TOTAL_SUPPLY = 1_000e18;
    uint16 constant TOKEN_SPLIT = 5_000;

    LBPStrategyBasic lbp;
    TokenLauncher tokenLauncher;
    LBPStrategyBasicNoValidation impl;
    MockERC20 token;
    MockERC20 implToken;
    MockDistributionStrategy mock;
    MigratorParameters migratorParams;

    uint256 nextTokenId;

    function setUpMigratorParams(
        address currency,
        uint24 fee,
        int24 tickSpacing,
        uint16 tokenSplitToAuction,
        address positionRecipient
    ) public view returns (MigratorParameters memory) {
        return MigratorParameters({
            currency: currency,
            fee: fee,
            tickSpacing: tickSpacing,
            tokenSplitToAuction: tokenSplitToAuction,
            auctionFactory: address(mock),
            positionRecipient: positionRecipient,
            migrationBlock: uint64(block.number + 1_000)
        });
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_URL"), 23097193);
        mock = new MockDistributionStrategy();
        tokenLauncher = new TokenLauncher(IAllowanceTransfer(PERMIT2));

        // Deploy the token and give the total supply to the token launcher
        token = MockERC20(0x1111111111111111111111111111111111111111); // make token address > address(0) but less than DAI
        implToken = new MockERC20("Test Token", "TEST", TOTAL_SUPPLY, address(tokenLauncher));
        vm.etch(0x1111111111111111111111111111111111111111, address(implToken).code);
        deal(address(token), address(tokenLauncher), TOTAL_SUPPLY);

        nextTokenId = IPositionManager(POSITION_MANAGER).nextTokenId();

        // give 1_000 DAI to this address
        deal(DAI, address(this), 1_000e18);

        migratorParams = setUpMigratorParams(address(0), 500, 1, TOKEN_SPLIT, address(3));

        // Get the hook address with BEFORE_INITIALIZE permission
        address hookAddress = HookAddressHelper.getHookAddress(Hooks.BEFORE_INITIALIZE_FLAG);

        // set the address of the lbp
        lbp = LBPStrategyBasic(hookAddress);

        // Deploy the contract without address validation. This is because it validates the address in the constructor which is not set yet
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            migratorParams,
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // Set up the hook contract at the correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        assertEq(lbp.token(), address(token));
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
        assertEq(fee, migratorParams.fee);
        assertEq(tickSpacing, migratorParams.tickSpacing);
        assertEq(address(hooks), address(lbp));
    }

    /**
     * @notice Helper function to set up test environment with a fuzzed total supply
     * @param totalSupply The total supply of tokens to use for the test
     */
    function setUpWithSupply(uint128 totalSupply) internal {
        // Bound the total supply to reasonable values
        totalSupply = uint128(bound(totalSupply, 0, type(uint128).max));

        // Deploy the token and give the total supply to the token launcher
        token = MockERC20(0x1111111111111111111111111111111111111111); // make token address > address(0) but less than DAI
        implToken = new MockERC20("Test Token", "TEST", totalSupply, address(tokenLauncher));
        vm.etch(0x1111111111111111111111111111111111111111, address(implToken).code);
        deal(address(token), address(tokenLauncher), totalSupply);

        // Get the hook address with BEFORE_INITIALIZE permission
        address hookAddress = HookAddressHelper.getHookAddress(Hooks.BEFORE_INITIALIZE_FLAG);

        // set the address of the lbp
        lbp = LBPStrategyBasic(hookAddress);

        // Deploy the contract without address validation. This is because it validates the address in the constructor which is not set yet
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            migratorParams,
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // Set up the hook contract at the correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        assertEq(lbp.token(), address(token));
        assertEq(lbp.currency(), address(0));
        assertEq(lbp.totalSupply(), totalSupply);
        assertEq(address(lbp.positionManager()), POSITION_MANAGER);
        assertEq(lbp.positionRecipient(), address(3));
        assertEq(lbp.migrationBlock(), uint64(block.number + 1_000));
        assertEq(lbp.auctionFactory(), address(mock));
        assertEq(address(lbp.auction()), address(0));
        assertEq(address(lbp.poolManager()), POOL_MANAGER);
    }

    function test_setUp_revertsWithTokenSplitTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.TokenSplitTooHigh.selector, TOKEN_SPLIT + 1));
        new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(address(0), 500, 100, TOKEN_SPLIT + 1, address(3)), // too many tokens would be sent to the auction
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidTickSpacing_tooLow() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.InvalidTickSpacing.selector, TickMath.MIN_TICK_SPACING - 1)
        );
        new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(address(0), 500, TickMath.MIN_TICK_SPACING - 1, TOKEN_SPLIT, address(3)), // tick spacing cannot be less than min tick spacing
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidTickSpacing_tooHigh() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.InvalidTickSpacing.selector, TickMath.MAX_TICK_SPACING + 1)
        );
        new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(address(0), 500, TickMath.MAX_TICK_SPACING + 1, TOKEN_SPLIT, address(3)), // tick spacing cannot be less than min tick spacing
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidFee() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidFee.selector, LPFeeLibrary.MAX_LP_FEE + 1));
        new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(address(0), LPFeeLibrary.MAX_LP_FEE + 1, 100, TOKEN_SPLIT, address(3)), // fee cannot be greater than max fee
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidPositionRecipient_address0() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidPositionRecipient.selector, address(0)));
        new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(address(0), 500, 100, TOKEN_SPLIT, address(0)), // position recipient cannot be 0
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidPositionRecipient_address1() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidPositionRecipient.selector, address(1)));
        new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(address(0), 500, 100, TOKEN_SPLIT, address(1)), // position recipient cannot be address(1) - position manager correlates this to msg.sender
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidPositionRecipient_address2() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidPositionRecipient.selector, address(2)));
        new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(address(0), 500, 100, TOKEN_SPLIT, address(2)), // position recipient cannot be address(2) - position manager correlates this to address(this)
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidTokenAndCurrency() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidTokenAndCurrency.selector, address(token)));
        new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(address(token), 500, 100, TOKEN_SPLIT, address(3)), // token and currency cannot be the same
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_onTokenReceived_revertsWithInvalidAmountReceived() public {
        vm.prank(address(tokenLauncher));
        ERC20(token).transfer(address(lbp), TOTAL_SUPPLY - 1); // incorrect amount of tokens were transferred to the contract
        vm.expectRevert(
            abi.encodeWithSelector(IDistributionContract.InvalidAmountReceived.selector, TOTAL_SUPPLY, TOTAL_SUPPLY - 1)
        );
        lbp.onTokensReceived();
    }

    function test_onTokenReceived_succeeds() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY); // transfer all the tokens from the token launcher contract to the lbp contract
        lbp.onTokensReceived();

        // verify auction is created and set
        assertNotEq(address(lbp.auction()), address(0));
        // Verify half of the tokens are in the auction and half are in the LBP
        assertEq(token.balanceOf(address(lbp.auction())), TOTAL_SUPPLY * 5000 / 1_0000); // half of the tokens are in the auction
        assertEq(token.balanceOf(address(lbp)), TOTAL_SUPPLY * 5000 / 1_0000); // half of the tokens are in the LBP
    }

    // Fuzzed version of the same test
    function test_fuzz_onTokenReceived_succeeds(uint128 totalSupply) public {
        setUpWithSupply(totalSupply);

        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply); // transfer all the tokens from the token launcher contract to the lbp contract
        lbp.onTokensReceived();

        // verify auction is created and set
        assertNotEq(address(lbp.auction()), address(0));
        // Verify half of the tokens are in the auction and half are in the LBP
        // Ex: 13 * 5 / 10 = 6    6 goes to auction. 7 goes to LBP
        assertEq(token.balanceOf(address(lbp.auction())), FullMath.mulDiv(totalSupply, 5000, 10_000)); // half of the tokens are in the auction
        assertEq(token.balanceOf(address(lbp)), totalSupply - FullMath.mulDiv(totalSupply, 5000, 10_000)); // half of the tokens are in the LBP
    }

    function test_setInitialPrice_revertsWithOnlyAuctionCanSetPrice() public {
        vm.expectRevert(
            abi.encodeWithSelector(ISubscriber.OnlyAuctionCanSetPrice.selector, address(lbp.auction()), address(this))
        );
        lbp.setInitialPrice(TOTAL_SUPPLY, TOTAL_SUPPLY);
    }

    function test_setInitialPrice_revertsWithInvalidCurrencyAmount() public {
        vm.deal(address(lbp.auction()), TOTAL_SUPPLY); // auction has tokens
        vm.prank(address(lbp.auction()));
        vm.expectRevert(
            abi.encodeWithSelector(ISubscriber.InvalidCurrencyAmount.selector, TOTAL_SUPPLY - 1, TOTAL_SUPPLY)
        );
        lbp.setInitialPrice{value: TOTAL_SUPPLY - 1}(TOTAL_SUPPLY, TOTAL_SUPPLY); // incorrect amount of ETH is transferred
    }

    function test_setInitialPrice_succeeds() public {
        vm.deal(address(lbp.auction()), TOTAL_SUPPLY); // auction has tokens
        vm.prank(address(lbp.auction()));

        vm.expectEmit(false, false, false, true);
        emit InitialPriceSet(TickMath.getSqrtPriceAtTick(0), TOTAL_SUPPLY, TOTAL_SUPPLY);
        lbp.setInitialPrice{value: TOTAL_SUPPLY}(TOTAL_SUPPLY, TOTAL_SUPPLY);

        // Verify the pool was initialized
        assertEq(lbp.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(0));
        assertEq(lbp.initialTokenAmount(), TOTAL_SUPPLY);
        assertEq(lbp.initialCurrencyAmount(), TOTAL_SUPPLY);
        assertEq(address(lbp).balance, TOTAL_SUPPLY);
    }

    function test_setInitialPrice_revertsWithNonETHCurrencyCannotReceiveETH() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        // does not need to have correct hook address because not migrating yet
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(DAI, 500, 100, TOKEN_SPLIT, address(3)),
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // First, we need to initialize the auction by sending tokens to the LBP
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        // give the auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        // Give the auction contract some ETH so it can attempt to send it (which should fail)
        vm.deal(address(lbp.auction()), 1e18);

        vm.prank(address(lbp.auction()));
        vm.expectRevert(abi.encodeWithSelector(ISubscriber.NonETHCurrencyCannotReceiveETH.selector, DAI));
        lbp.setInitialPrice{value: 1e18}(TOTAL_SUPPLY, 1e18); // attempts to send ETH when DAI is set as the currency
    }

    function test_setInitialPrice_withNonETHCurrency_succeeds() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        // does not need to have correct hook address because not migrating yet
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(DAI, 500, 100, TOKEN_SPLIT, address(3)),
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.stopPrank();

        // give the auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), 1_000e18);

        vm.expectEmit(false, false, false, true);
        emit InitialPriceSet(TickMath.getSqrtPriceAtTick(0), TOTAL_SUPPLY, TOTAL_SUPPLY);

        lbp.setInitialPrice(TOTAL_SUPPLY, TOTAL_SUPPLY);
        vm.stopPrank();

        // Verify values are set correctly
        assertEq(lbp.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(0));
        assertEq(lbp.initialTokenAmount(), TOTAL_SUPPLY);
        assertEq(lbp.initialCurrencyAmount(), TOTAL_SUPPLY);

        // Verify the auction has no DAI and the LBP has all the DAI
        assertEq(ERC20(DAI).balanceOf(address(lbp.auction())), 0);
        assertEq(ERC20(DAI).balanceOf(address(lbp)), TOTAL_SUPPLY);
    }

    function test_priceSetCorrectly() public {
        uint256 priceX192 = FullMath.mulDiv(1e18, 2 ** 192, 1e18);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(priceX192));

        assertEq(sqrtPriceX96, 79228162514264337593543950336);

        priceX192 = FullMath.mulDiv(100e18, 2 ** 192, 1e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));

        assertEq(sqrtPriceX96, 792281625142643375935439503360);

        priceX192 = FullMath.mulDiv(1e18, 2 ** 192, 100e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));

        assertEq(sqrtPriceX96, 7922816251426433759354395033);

        priceX192 = FullMath.mulDiv(111e18, 2 ** 192, 333e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));

        assertEq(sqrtPriceX96, 45742400955009932534161870629);

        priceX192 = FullMath.mulDiv(333e18, 2 ** 192, 111e18);
        sqrtPriceX96 = uint160(Math.sqrt(priceX192));

        assertEq(sqrtPriceX96, 137227202865029797602485611888);
    }

    function test_migrate_revertsWithMigrationNotAllowed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.MigrationNotAllowed.selector, lbp.migrationBlock(), block.number)
        ); // migration block is not reached
        lbp.migrate();
    }

    function test_migrate_revertsWithAlreadyInitialized() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        // give the auction ETH
        deal(address(lbp.auction()), 500e18);

        // set the initial price
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 500e18}(TOTAL_SUPPLY / 2, 500e18);

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
        lbp.onTokensReceived();

        vm.roll(lbp.migrationBlock()); // fast forward to the migration block
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, 0)); // invalid sqrt price
        // setInitialPrice was never called by the auction
        lbp.migrate();
    }

    function test_migrate_fullRange_succeeds() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        // give the auction ETH
        deal(address(lbp.auction()), 500e18);

        // set the initial price
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 500e18}(TOTAL_SUPPLY / 2, 500e18);

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

    function test_migrate_fullRange_withNonETHCurrency_succeeds() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(DAI, 500, 1, TOKEN_SPLIT, address(3)),
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // Set up the hook contract at the correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.stopPrank();

        // give the auction DAI
        deal(DAI, address(lbp.auction()), TOTAL_SUPPLY / 2);

        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), TOTAL_SUPPLY / 2);

        lbp.setInitialPrice(TOTAL_SUPPLY / 2, TOTAL_SUPPLY / 2);
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

    function test_fuzz_migrate_fullRange_succeeds() public {
        uint128 totalSupply = 16306210629269603649197458450808237841;
        uint24 fee = 5357347;
        int24 tickSpacing = 0;

        totalSupply = uint128(bound(totalSupply, 1, type(uint128).max));
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));

        console2.log("totalSupply", totalSupply);
        console2.log("fee", fee);
        console2.log("tickSpacing", tickSpacing);

        setUpWithSupply(totalSupply);

        impl = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            setUpMigratorParams(address(0), fee, tickSpacing, TOKEN_SPLIT, address(3)),
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // Set up the hook contract at the correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived();

        // give the auction ETH
        deal(address(lbp.auction()), totalSupply - FullMath.mulDiv(totalSupply, 5000, 10_000));

        // set the initial price
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: totalSupply - FullMath.mulDiv(totalSupply, 5000, 10_000)}(
            totalSupply - FullMath.mulDiv(totalSupply, 5000, 10_000),
            totalSupply - FullMath.mulDiv(totalSupply, 5000, 10_000)
        );

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        vm.prank(address(lbp));
        lbp.migrate();

        // verify the pool was initialized
        assertEq(lbp.initialSqrtPriceX96(), TickMath.getSqrtPriceAtTick(0));
        assertEq(lbp.initialTokenAmount(), totalSupply - FullMath.mulDiv(totalSupply, 5000, 10_000));
        assertEq(lbp.initialCurrencyAmount(), totalSupply - FullMath.mulDiv(totalSupply, 5000, 10_000));
        assertEq(address(lbp).balance, 0);

        (PoolKey memory poolKey, PositionInfo info) =
            IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId);
        assertEq(Currency.unwrap(poolKey.currency0), address(0));
        assertEq(Currency.unwrap(poolKey.currency1), address(token));
        assertEq(poolKey.fee, fee);
        assertEq(poolKey.tickSpacing, tickSpacing);
        assertEq(info.tickLower(), TickMath.MIN_TICK / tickSpacing * tickSpacing);
        assertEq(info.tickUpper(), TickMath.MAX_TICK / tickSpacing * tickSpacing);

        assertLe(TickMath.MIN_TICK, info.tickLower());
        assertGe(TickMath.MAX_TICK, info.tickUpper());
    }

    function test_migrate_withOneSidedPosition_succeeds() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY); // send all tokens to the LBP
        lbp.onTokensReceived();

        uint256 ethAmt = 500e18;
        deal(address(lbp.auction()), ethAmt); // give the auction ETH
        uint256 tokenAmt = lbp.reserveSupply() / 2;
        // price is token / eth

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: ethAmt}(tokenAmt, ethAmt);

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
        assertEq(info2.tickUpper(), TickMath.getTickAtSqrtPrice(lbp.initialSqrtPriceX96())); // upper tick is inclusive
    }

    function test_migrate_withNonETHCurrency_withOneSidedPosition_succeeds() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(DAI, 500, 20, TOKEN_SPLIT, address(3)),
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // Set up the hook contract at the correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.stopPrank();

        uint256 daiAmt = TOTAL_SUPPLY / 2;

        // give the auction DAI
        deal(DAI, address(lbp.auction()), TOTAL_SUPPLY / 2);

        vm.prank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), TOTAL_SUPPLY / 2);

        uint256 tokenAmt = lbp.reserveSupply() / 2;
        // price is dai / token

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice(tokenAmt, daiAmt);

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        lbp.migrate();

        // assert auction has no DAI
        assertEq(ERC20(DAI).balanceOf(address(lbp.auction())), 0);

        // assert position was created at the correct token id
        (PoolKey memory poolKey, PositionInfo info) =
            IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId);
        assertEq(Currency.unwrap(poolKey.currency0), address(token));
        assertEq(Currency.unwrap(poolKey.currency1), address(DAI));
        assertEq(poolKey.fee, 500);
        assertEq(poolKey.tickSpacing, 20);
        assertEq(info.tickLower(), -887260);
        assertEq(info.tickUpper(), 887260);

        // assert one sided position was created at the correct token id
        (PoolKey memory poolKey2, PositionInfo info2) =
            IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(nextTokenId + 1);
        assertEq(Currency.unwrap(poolKey2.currency0), address(token));
        assertEq(Currency.unwrap(poolKey2.currency1), address(DAI));
        assertEq(poolKey2.fee, 500);
        assertEq(poolKey2.tickSpacing, 20);
        assertEq(info2.tickLower(), 6940);
        assertEq(info2.tickUpper(), 887260);
    }

    function test_fuzz_migrate(
        uint16 tokenSplitToAuction,
        uint24 fee,
        int24 tickSpacing,
        uint256 ethRaised,
        uint160 sqrtPriceX96
    ) public {
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        tokenSplitToAuction = uint16(bound(tokenSplitToAuction, 0, 5000));
        tickSpacing = int24(bound(tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));

        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));

        // Deploy the contract with currency set to DAI (non-ETH currency)
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(address(0), fee, tickSpacing, tokenSplitToAuction, address(3)),
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // Set up the hook contract at the correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.stopPrank();
    }

    function test_onTokensReceived_gas() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.snapshotGasLastCall("onTokensReceived");
    }

    function test_setInitialPrice_withETH_gas() public {
        vm.deal(address(lbp.auction()), TOTAL_SUPPLY); // auction has tokens
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 1e18}(TOTAL_SUPPLY, 1e18);
        vm.snapshotGasLastCall("setInitialPriceWithETH");
    }

    function test_setInitialPrice_withNonETHCurrency_gas() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(DAI, 500, 100, TOKEN_SPLIT, address(3)),
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.stopPrank();

        // give the auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), 1_000e18);

        lbp.setInitialPrice(TOTAL_SUPPLY, TOTAL_SUPPLY);
        vm.snapshotGasLastCall("setInitialPriceWithNonETHCurrency");
    }

    function test_migrate_withETH_gas() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        // give the auction ETH
        deal(address(lbp.auction()), 500e18);

        // set the initial price
        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: 500e18}(TOTAL_SUPPLY / 2, 500e18);

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        vm.prank(address(lbp));
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithETH");
    }

    function test_migrate_withETH_withOneSidedPosition_gas() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();

        uint256 ethAmt = 500e18;
        deal(address(lbp.auction()), ethAmt); // give the auction ETH
        uint256 tokenAmt = lbp.reserveSupply() / 2;
        // price is token / eth

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice{value: ethAmt}(tokenAmt, ethAmt);

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        vm.prank(address(lbp));
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithETH_withOneSidedPosition");
    }

    function test_migrate_withNonETHCurrency_gas() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(DAI, 500, 1, TOKEN_SPLIT, address(3)),
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.stopPrank();

        // give the auction DAI
        deal(DAI, address(lbp.auction()), 1_000e18);

        vm.startPrank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), 1_000e18);

        lbp.setInitialPrice(TOTAL_SUPPLY / 2, TOTAL_SUPPLY / 2);
        vm.stopPrank();

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency");
    }

    function test_migrate_withNonETHCurrency_withOneSidedPosition_gas() public {
        // Deploy the contract with currency set to DAI (non-ETH currency)
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            TOTAL_SUPPLY,
            setUpMigratorParams(DAI, 500, 20, TOKEN_SPLIT, address(3)),
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // Set up the hook contract at the correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 10);

        // Update the PoolKey hook address (stored in slot 6)
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 6);

        // initialize the auction by sending tokens to the LBP
        vm.startPrank(address(tokenLauncher));
        token.transfer(address(lbp), TOTAL_SUPPLY);
        lbp.onTokensReceived();
        vm.stopPrank();

        uint256 daiAmt = TOTAL_SUPPLY / 2;

        // give the auction DAI
        deal(DAI, address(lbp.auction()), TOTAL_SUPPLY / 2);

        vm.prank(address(lbp.auction()));
        ERC20(DAI).approve(address(lbp), TOTAL_SUPPLY / 2);

        uint256 tokenAmt = lbp.reserveSupply() / 2;
        // price is dai / token

        vm.prank(address(lbp.auction()));
        lbp.setInitialPrice(tokenAmt, daiAmt);

        // fast forward to the migration block
        vm.roll(lbp.migrationBlock());

        // migrate
        lbp.migrate();
        vm.snapshotGasLastCall("migrateWithNonETHCurrency_withOneSidedPosition");
    }
}
