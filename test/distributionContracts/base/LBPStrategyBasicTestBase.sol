// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LBPStrategyBasic} from "../../../src/distributionContracts/LBPStrategyBasic.sol";
import {MigratorParameters} from "../../../src/distributionContracts/LBPStrategyBasic.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockDistributionStrategy} from "../../mocks/MockDistributionStrategy.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LBPStrategyBasicNoValidation} from "../../mocks/LBPStrategyBasicNoValidation.sol";
import {HookAddressHelper} from "../../mocks/HookAddressHelper.sol";
import {TokenLauncher} from "../../../src/TokenLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

abstract contract LBPStrategyBasicTestBase is Test {
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

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("FORK_URL"), FORK_BLOCK);
        _setupContracts();
        _setupDefaultMigratorParams();
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
        address hookAddress = HookAddressHelper.getHookAddress(Hooks.BEFORE_INITIALIZE_FLAG);
        lbp = LBPStrategyBasic(hookAddress);

        // Deploy implementation
        impl = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            migratorParams,
            bytes(""),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            IWETH9(WETH9)
        );

        // Setup hook contract at correct address
        HookAddressHelper.setupHookContract(vm, address(impl), address(lbp), 9);
        HookAddressHelper.updatePoolKeyHook(vm, address(lbp), address(lbp), 5);
    }

    function _verifyInitialState() internal view {
        assertEq(lbp.token(), address(token));
        assertEq(lbp.currency(), migratorParams.currency);
        assertEq(lbp.totalSupply(), DEFAULT_TOTAL_SUPPLY);
        assertEq(address(lbp.positionManager()), POSITION_MANAGER);
        assertEq(lbp.positionRecipient(), migratorParams.positionRecipient);
        assertEq(lbp.migrationBlock(), uint64(block.number + 1_000));
        assertEq(lbp.auctionFactory(), address(mock));
        assertEq(address(lbp.auction()), address(0));
        assertEq(address(lbp.poolManager()), POOL_MANAGER);

        _verifyPoolKey();
    }

    function _verifyPoolKey() internal view {
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = lbp.key();

        assertEq(Currency.unwrap(currency0), migratorParams.currency);
        assertEq(Currency.unwrap(currency1), address(token));
        assertEq(fee, migratorParams.fee);
        assertEq(tickSpacing, migratorParams.tickSpacing);
        assertEq(address(hooks), address(lbp));
    }

    // Helper function to create migrator params
    function createMigratorParams(
        address currency,
        uint24 fee,
        int24 tickSpacing,
        uint16 tokenSplitToAuction,
        address positionRecipient
    ) internal view returns (MigratorParameters memory) {
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

    // Helper to setup with custom total supply
    function setupWithSupply(uint128 totalSupply) internal {
        totalSupply = uint128(bound(totalSupply, 0, type(uint128).max));
        _deployLBPStrategy(totalSupply);
    }

    // Helper to setup with custom currency (e.g., DAI)
    function setupWithCurrency(address currency) internal {
        migratorParams = createMigratorParams(
            currency,
            migratorParams.fee,
            migratorParams.tickSpacing,
            migratorParams.tokenSplitToAuction,
            migratorParams.positionRecipient
        );
        _deployLBPStrategy(DEFAULT_TOTAL_SUPPLY);
    }
}
