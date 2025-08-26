// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LBPTestHelpers} from "../helpers/LBPTestHelpers.sol";
import {LBPStrategyBasic} from "../../../src/distributionContracts/LBPStrategyBasic.sol";
import {MigratorParameters} from "../../../src/distributionContracts/LBPStrategyBasic.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockDistributionStrategy} from "../../mocks/MockDistributionStrategy.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LBPStrategyBasicNoValidation} from "../../mocks/LBPStrategyBasicNoValidation.sol";
import {TokenLauncher} from "../../../src/TokenLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";
import {AuctionStepsBuilder} from "twap-auction/test/utils/AuctionStepsBuilder.sol";

abstract contract LBPStrategyBasicTestBase is LBPTestHelpers {
    using AuctionStepsBuilder for bytes;

    // Constants
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Default values
    uint128 constant DEFAULT_TOTAL_SUPPLY = 1_000e18;
    uint16 constant DEFAULT_TOKEN_SPLIT = 5_000;
    uint256 constant FORK_BLOCK = 23097193;

    // Test token address (make it > address(0) but < DAI)
    address constant TEST_TOKEN_ADDRESS = 0x1111111111111111111111111111111111111111;

    uint160 constant HOOK_PERMISSION_COUNT = 14;
    uint160 internal constant CLEAR_ALL_HOOK_PERMISSIONS_MASK = ~uint160(0) << (HOOK_PERMISSION_COUNT);

    // Events
    event Notified(bytes data);
    event Migrated(PoolKey indexed key, uint160 initialSqrtPriceX96);

    // State variables
    LBPStrategyBasic lbp;
    TokenLauncher tokenLauncher;
    LBPStrategyBasicNoValidation impl;
    MockERC20 token;
    MockERC20 implToken;
    MockDistributionStrategy mock;
    MigratorParameters migratorParams;
    uint256 nextTokenId;
    AuctionParameters auctionParams;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("FORK_URL"), FORK_BLOCK);
        _setupContracts();
        _setupDefaultMigratorParams();
        auctionParams = createAuctionParams();
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);
        _verifyInitialState();
    }

    function _setupContracts() internal {
        mock = new MockDistributionStrategy();
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
            address(3) // position recipient
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
        lbp = LBPStrategyBasic(hookAddress);

        // Deploy implementation
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            migratorParams,
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            IWETH9(WETH9)
        );

        vm.etch(address(lbp), address(impl).code);

        // Copy storage slots
        for (uint256 i = 0; i < 12; i++) {
            bytes32 value = vm.load(address(impl), bytes32(i));
            vm.store(address(lbp), bytes32(i), value);
        }
    }

    function _verifyInitialState() internal view {
        assertEq(lbp.token(), address(token));
        assertEq(lbp.currency(), migratorParams.currency);
        assertEq(lbp.totalSupply(), DEFAULT_TOTAL_SUPPLY);
        assertEq(address(lbp.positionManager()), POSITION_MANAGER);
        assertEq(lbp.positionRecipient(), migratorParams.positionRecipient);
        assertEq(lbp.migrationBlock(), uint64(block.number + 1_000));
        assertEq(address(lbp.auction()), address(0));
        assertEq(address(lbp.poolManager()), POOL_MANAGER);
        assertEq(lbp.poolLPFee(), migratorParams.poolLPFee);
        assertEq(lbp.poolTickSpacing(), migratorParams.poolTickSpacing);
    }

    // Helper function to create migrator params
    function createMigratorParams(
        address currency,
        uint24 poolLPFee,
        int24 poolTickSpacing,
        uint16 tokenSplitToAuction,
        address positionRecipient
    ) internal view returns (MigratorParameters memory) {
        return MigratorParameters({
            currency: currency,
            poolLPFee: poolLPFee,
            poolTickSpacing: poolTickSpacing,
            tokenSplitToAuction: tokenSplitToAuction,
            positionRecipient: positionRecipient,
            migrationBlock: uint64(block.number + 1_000)
        });
    }

    function createAuctionParams() internal returns (AuctionParameters memory) {
        bytes memory auctionStepsData = AuctionStepsBuilder.init().addStep(100e3, 100);

        return AuctionParameters({
            currency: address(0), // ETH
            tokensRecipient: makeAddr("tokensRecipient"), // Some valid address
            fundsRecipient: makeAddr("fundsRecipient"), // Some valid address
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            claimBlock: uint64(block.number + 100),
            tickSpacing: 1e6, // Valid tick spacing for auctions
            validationHook: address(0), // No validation hook
            floorPrice: 1e6, // 1 ETH as floor price
            auctionStepsData: auctionStepsData
        });
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
            migratorParams.positionRecipient
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);
    }

    // Helper to setup with custom total supply and token split
    function setupWithSupplyAndTokenSplit(uint128 totalSupply, uint16 tokenSplit) internal {
        migratorParams = createMigratorParams(
            address(0), // ETH as currency (same as default)
            500, // fee (same as default)
            1, // tick spacing (same as default)
            tokenSplit, // Use custom tokenSplit
            address(3) // position recipient (same as default)
        );
        _deployLBPStrategy(totalSupply);
    }
}
