// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LBPTestHelpers} from "../helpers/LBPTestHelpers.sol";
import {LBPStrategyBasic} from "../../../src/distributionContracts/LBPStrategyBasic.sol";
import {MigratorParameters} from "../../../src/distributionContracts/LBPStrategyBasic.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LBPStrategyBasicNoValidation} from "../../mocks/LBPStrategyBasicNoValidation.sol";
import {TokenLauncher} from "../../../src/TokenLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";
import {AuctionStepsBuilder} from "twap-auction/test/utils/AuctionStepsBuilder.sol";
import {ILBPStrategyBasic} from "../../../src/interfaces/ILBPStrategyBasic.sol";
import {AuctionFactory} from "twap-auction/src/AuctionFactory.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IAuction} from "twap-auction/src/interfaces/IAuction.sol";
import {ValueX7} from "twap-auction/src/libraries/CheckpointLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

abstract contract LBPStrategyBasicTestBase is LBPTestHelpers {
    using AuctionStepsBuilder for bytes;
    using FixedPointMathLib for *;

    // Constants
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Default values
    uint128 constant DEFAULT_TOTAL_SUPPLY = 1_000e18;
    uint24 constant DEFAULT_TOKEN_SPLIT = 5e6;
    uint256 constant FORK_BLOCK = 23097193;
    uint256 public constant FLOOR_PRICE = 1000 << FixedPoint96.RESOLUTION;
    uint256 public constant TICK_SPACING = 100 << FixedPoint96.RESOLUTION;

    // Test token address (make it > address(0) but < DAI)
    address constant TEST_TOKEN_ADDRESS = 0x1111111111111111111111111111111111111111;

    uint160 constant HOOK_PERMISSION_COUNT = 14;
    uint160 internal constant CLEAR_ALL_HOOK_PERMISSIONS_MASK = ~uint160(0) << (HOOK_PERMISSION_COUNT);

    address testOperator = makeAddr("testOperator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Events
    event Notified(bytes data);
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    // State variables
    LBPStrategyBasic lbp;
    TokenLauncher tokenLauncher;
    LBPStrategyBasicNoValidation impl;
    MockERC20 token;
    MockERC20 implToken;
    AuctionFactory auctionFactory;
    MigratorParameters migratorParams;
    uint256 nextTokenId;
    bytes auctionParams;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("FORK_URL"), FORK_BLOCK);
        _setupContracts();
        _setupDefaultMigratorParams();
        _setupDefaultAuctionParams();
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);
        _verifyInitialState();
    }

    function _setupContracts() internal {
        auctionFactory = new AuctionFactory();
        tokenLauncher = new TokenLauncher(IAllowanceTransfer(PERMIT2));
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
            true, // createOneSidedTokenPosition,
            true // createOneSidedCurrencyPosition
        );
    }

    function _deployLBPStrategy(uint128 totalSupply) internal {
        // Deploy token and give supply to token launcher
        token = MockERC20(TEST_TOKEN_ADDRESS);
        implToken = new MockERC20("Test Token", "TEST", totalSupply, address(tokenLauncher));
        vm.etch(TEST_TOKEN_ADDRESS, address(implToken).code);
        deal(address(token), address(tokenLauncher), totalSupply);
        // Get hook address with BEFORE_INITIALIZE permission
        address hookAddress = address(
            uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | Hooks.BEFORE_INITIALIZE_FLAG)
        );
        lbp = LBPStrategyBasic(payable(hookAddress));
        // Deploy implementation
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            migratorParams,
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
        vm.etch(address(lbp), address(impl).code);

        LBPStrategyBasicNoValidation(payable(address(lbp))).setAuctionParameters(auctionParams);
    }

    function _verifyInitialState() internal view {
        assertEq(lbp.token(), address(token));
        assertEq(lbp.currency(), migratorParams.currency);
        assertEq(lbp.totalSupply(), DEFAULT_TOTAL_SUPPLY);
        assertEq(address(lbp.positionManager()), POSITION_MANAGER);
        assertEq(lbp.positionRecipient(), migratorParams.positionRecipient);
        assertEq(lbp.migrationBlock(), uint64(block.number + 500));
        assertEq(address(lbp.auction()), address(0));
        assertEq(address(lbp.poolManager()), POOL_MANAGER);
        assertEq(lbp.poolLPFee(), migratorParams.poolLPFee);
        assertEq(lbp.poolTickSpacing(), migratorParams.poolTickSpacing);
        assertEq(lbp.auctionParameters(), auctionParams);
    }

    // Helper function to create migrator params
    function createMigratorParams(
        address currency,
        uint24 poolLPFee,
        int24 poolTickSpacing,
        uint24 tokenSplitToAuction,
        address positionRecipient,
        uint64 migrationBlock,
        uint64 sweepBlock,
        address operator,
        bool createOneSidedTokenPosition,
        bool createOneSidedCurrencyPosition
    ) internal view returns (MigratorParameters memory) {
        return MigratorParameters({
            currency: currency,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            tokenSplitToAuction: tokenSplitToAuction,
            auctionFactory: address(auctionFactory),
            positionRecipient: positionRecipient,
            migrationBlock: migrationBlock,
            sweepBlock: sweepBlock,
            operator: operator,
            createOneSidedTokenPosition: createOneSidedTokenPosition,
            createOneSidedCurrencyPosition: createOneSidedCurrencyPosition
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
            migratorParams.tokenSplitToAuction,
            migratorParams.positionRecipient,
            migratorParams.migrationBlock,
            migratorParams.sweepBlock,
            migratorParams.operator,
            migratorParams.createOneSidedTokenPosition,
            migratorParams.createOneSidedCurrencyPosition
        );
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
            true, // createOneSidedTokenPosition
            true // createOneSidedCurrencyPosition
        );
        _deployLBPStrategy(totalSupply);
    }

    // ============ Core Bid Submission Helpers ============

    /// @notice Submits a bid for ETH auction
    /// @dev Handles ETH transfer, event emission, and bid ID validation
    function _submitBid(
        IAuction auction,
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
        IAuction auction,
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
