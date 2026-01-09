// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LBPTestHelpers} from "../helpers/LBPTestHelpers.sol";
import {AdvancedLBPStrategy} from "@lbp/strategies/AdvancedLBPStrategy.sol";
import {MigratorParameters} from "@lbp/strategies/LBPStrategyBase.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {AdvancedLBPStrategyNoValidation} from "../../../mocks/AdvancedLBPStrategyNoValidation.sol";
import {FullRangeLBPStrategy} from "@lbp/strategies/FullRangeLBPStrategy.sol";
import {FullRangeLBPStrategyNoValidation} from "../../../mocks/FullRangeLBPStrategyNoValidation.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "continuous-clearing-auction/test/utils/AuctionStepsBuilder.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/src/ContinuousClearingAuctionFactory.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IContinuousClearingAuction} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {ValueX7} from "continuous-clearing-auction/src/libraries/CheckpointLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";

abstract contract AdvancedLBPStrategyTestBase is LBPTestHelpers {
    using AuctionStepsBuilder for bytes;
    using FixedPointMathLib for *;

    // Default values
    uint128 constant DEFAULT_TOTAL_SUPPLY = 1_000e18;
    uint24 constant DEFAULT_TOKEN_SPLIT = 5e6;
    uint256 constant FORK_BLOCK = 23097193;
    uint256 public constant FLOOR_PRICE = 1000 << FixedPoint96.RESOLUTION;
    uint256 public constant TICK_SPACING = 100 << FixedPoint96.RESOLUTION;
    uint128 constant DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP = type(uint128).max;

    // Test token address (make it > address(0) but < DAI)
    address constant TEST_TOKEN_ADDRESS = 0x1111111111111111111111111111111111111111;

    // Events
    event Notified(bytes data);
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    // State variables
    ILBPStrategyBase lbp;
    LiquidityLauncher liquidityLauncher;
    ILBPStrategyBase impl;
    MockERC20 token;
    MockERC20 implToken;
    ContinuousClearingAuctionFactory initializerFactory;
    MigratorParameters migratorParams;
    uint256 nextTokenId;
    bytes auctionParams;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        _setupContracts();
        _setupDefaultMigratorParams();
        _setupDefaultAuctionParams();
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);
        _verifyInitialState();
    }

    function _setupContracts() internal {
        initializerFactory = new ContinuousClearingAuctionFactory();
        liquidityLauncher = new LiquidityLauncher(IAllowanceTransfer(PERMIT2));
        nextTokenId = IPositionManager(POSITION_MANAGER).nextTokenId();

        // Give test contract some DAI
        deal(DAI, address(this), 1_000e18);
    }

    function _setupDefaultMigratorParams() internal {
        migratorParams = createMigratorParams(
            address(0), // ETH as currency
            500, // fee
            1, // tick spacing
            DEFAULT_TOKEN_SPLIT,
            address(3), // position recipient
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            testOperator, // operator (receive function for checking ETH balance)
            DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP // maxCurrencyAmountForLP
        );
    }

    function _setUpToken(uint128 totalSupply) internal {
        token = MockERC20(TEST_TOKEN_ADDRESS);
        implToken = new MockERC20("Test Token", "TEST", totalSupply, address(liquidityLauncher));
        vm.etch(TEST_TOKEN_ADDRESS, address(implToken).code);
        deal(address(token), address(liquidityLauncher), totalSupply);
    }

    function _deployLBPStrategy(uint128 totalSupply) internal {
        _setUpToken(totalSupply);
        // Get hook address with BEFORE_INITIALIZE permission
        address hookAddress = address(
            uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | Hooks.BEFORE_INITIALIZE_FLAG)
        );
        lbp = AdvancedLBPStrategy(payable(hookAddress));
        // Deploy implementation
        impl = new AdvancedLBPStrategyNoValidation(
            address(token),
            totalSupply,
            migratorParams,
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            true,
            true
        );
        vm.etch(address(lbp), address(impl).code);

        AdvancedLBPStrategyNoValidation(payable(address(lbp))).setAuctionParameters(auctionParams);
    }

    function _deployFullRangeLBPStrategy(uint128 totalSupply) internal {
        _setUpToken(totalSupply);
        // Get hook address with BEFORE_INITIALIZE permission
        address hookAddress = address(
            uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | Hooks.BEFORE_INITIALIZE_FLAG)
        );
        lbp = FullRangeLBPStrategy(payable(hookAddress));
        impl = new FullRangeLBPStrategyNoValidation(
            address(token),
            totalSupply,
            migratorParams,
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
        vm.etch(address(lbp), address(impl).code);
        FullRangeLBPStrategyNoValidation(payable(address(lbp))).setAuctionParameters(auctionParams);
    }

    function _verifyInitialState() internal view {
        assertEq(lbp.token(), address(token));
        assertEq(lbp.currency(), migratorParams.currency);
        assertEq(lbp.totalSupply(), DEFAULT_TOTAL_SUPPLY);
        assertEq(address(lbp.positionManager()), POSITION_MANAGER);
        assertEq(address(AdvancedLBPStrategy(payable(address(lbp))).poolManager()), POOL_MANAGER);
        assertEq(lbp.positionRecipient(), migratorParams.positionRecipient);
        assertEq(lbp.migrationBlock(), uint64(block.number + 500));
        assertEq(address(lbp.initializer()), address(0));
        assertEq(lbp.poolLPFee(), migratorParams.poolLPFee);
        assertEq(lbp.poolTickSpacing(), migratorParams.poolTickSpacing);
        assertEq(lbp.maxCurrencyAmountForLP(), migratorParams.maxCurrencyAmountForLP);
        assertEq(lbp.initializerParameters(), auctionParams);
    }

    // Helper function to create migrator params
    function createMigratorParams(
        address currency,
        uint24 poolLPFee,
        int24 poolTickSpacing,
        uint24 tokenSplit,
        address positionRecipient,
        uint64 migrationBlock,
        uint64 sweepBlock,
        address operator,
        uint128 maxCurrencyAmountForLP
    ) internal view returns (MigratorParameters memory) {
        return MigratorParameters({
            currency: currency,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            tokenSplit: tokenSplit,
            initializerFactory: address(initializerFactory),
            positionRecipient: positionRecipient,
            migrationBlock: migrationBlock,
            sweepBlock: sweepBlock,
            operator: operator,
            maxCurrencyAmountForLP: maxCurrencyAmountForLP
        });
    }

    function createAuctionParamsWithCurrency(address currency) internal {
        bytes memory auctionStepsData = AuctionStepsBuilder.init().addStep(100e3, 50).addStep(100e3, 50);

        auctionParams = abi.encode(
            AuctionParameters({
                currency: currency, // Currency (could be ETH or ERC20)
                tokensRecipient: makeAddr("tokensRecipient"), // Some valid address
                fundsRecipient: address(1),
                startBlock: uint64(block.number),
                endBlock: uint64(block.number + 100),
                claimBlock: uint64(block.number + 100 + 10),
                tickSpacing: TICK_SPACING,
                validationHook: address(0), // No validation hook
                floorPrice: FLOOR_PRICE,
                requiredCurrencyRaised: 0,
                auctionStepsData: auctionStepsData
            })
        );
    }

    function _setupDefaultAuctionParams() internal {
        bytes memory auctionStepsData = AuctionStepsBuilder.init().addStep(100e3, 50).addStep(100e3, 50);

        auctionParams = abi.encode(
            AuctionParameters({
                currency: address(0), // ETH
                tokensRecipient: makeAddr("tokensRecipient"), // Some valid address
                fundsRecipient: address(1),
                startBlock: uint64(block.number),
                endBlock: uint64(block.number + 100),
                claimBlock: uint64(block.number + 100 + 10),
                tickSpacing: TICK_SPACING,
                validationHook: address(0), // No validation hook
                floorPrice: FLOOR_PRICE,
                requiredCurrencyRaised: 0,
                auctionStepsData: auctionStepsData
            })
        );
    }

    // Helper to setup with custom total supply
    function setupWithSupply(uint128 totalSupply) internal {
        _deployLBPStrategy(totalSupply);
    }

    // Helper to setup with custom currency (e.g., DAI)
    function setupWithCurrency(address currency) internal {
        migratorParams = createMigratorParams(
            currency,
            migratorParams.poolLPFee,
            migratorParams.poolTickSpacing,
            migratorParams.tokenSplit,
            migratorParams.positionRecipient,
            migratorParams.migrationBlock,
            migratorParams.sweepBlock,
            migratorParams.operator,
            migratorParams.maxCurrencyAmountForLP
        );
        createAuctionParamsWithCurrency(currency);
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);
    }

    // Helper to setup with custom total supply and token split
    function setupWithSupplyAndTokenSplit(uint128 totalSupply, uint24 tokenSplit, address currency) internal {
        migratorParams = createMigratorParams(
            currency, // ETH as currency (same as default)
            500, // fee (same as default)
            1, // tick spacing (same as default)
            tokenSplit, // Use custom tokenSplit
            address(3), // position recipient (same as default),
            uint64(block.number + 500), // migration block
            uint64(block.number + 1_000), // sweep block
            testOperator, // operator
            DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP // maxCurrencyAmountForLP
        );
        createAuctionParamsWithCurrency(currency);
        _deployLBPStrategy(totalSupply);
    }

    // ============ Core Bid Submission Helpers ============

    /// @notice Submits a bid for ETH auction
    /// @dev Handles ETH transfer, event emission, and bid ID validation
    function _submitBid(
        IContinuousClearingAuction auction,
        address bidder,
        uint128 tokenAmount,
        uint256 priceX96,
        uint256 prevPriceX96,
        uint256 expectedBidId
    ) internal returns (uint256) {
        uint128 inputAmount = tokenAmount;

        vm.deal(bidder, inputAmount);

        vm.prank(bidder);
        uint256 bidId = auction.submitBid{value: inputAmount}(
            priceX96, // maxPrice
            inputAmount, // amount
            bidder, // owner
            prevPriceX96, // prevTickPrice hint
            bytes("") // hookData
        );

        assertEq(bidId, expectedBidId);

        return bidId;
    }

    /// @notice Submits a bid for ERC20 auction
    /// @dev Assumes Permit2 approval is already set up
    function _submitBidNonEth(
        IContinuousClearingAuction auction,
        address bidder,
        uint128 tokenAmount,
        uint256 priceX96,
        uint256 prevPriceX96,
        uint256 expectedBidId
    ) internal returns (uint256) {
        uint128 inputAmount = tokenAmount;

        vm.prank(bidder);
        uint256 bidId = auction.submitBid(
            priceX96, // maxPrice
            inputAmount, // amount
            bidder, // owner
            prevPriceX96, // prevTickPrice hint
            bytes("") // hookData
        );

        assertEq(bidId, expectedBidId);

        return bidId;
    }

    function inputAmountForTokens(uint128 tokens, uint256 maxPrice) internal pure returns (uint128) {
        return uint128(tokens.fullMulDivUp(maxPrice, FixedPoint96.Q96));
    }

    function tickNumberToPriceX96(uint256 tickNumber) internal pure returns (uint256) {
        return FLOOR_PRICE + (tickNumber - 1) * TICK_SPACING;
    }
}
