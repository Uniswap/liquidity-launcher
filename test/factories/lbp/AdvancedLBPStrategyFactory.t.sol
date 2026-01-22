// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {AdvancedLBPStrategyFactory} from "@lbp/factories/AdvancedLBPStrategyFactory.sol";
import {AdvancedLBPStrategy} from "@lbp/strategies/AdvancedLBPStrategy.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MigratorParameters} from "src/types/MigratorParameters.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SelfInitializerHook} from "periphery/hooks/SelfInitializerHook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {AuctionParameters} from "@uniswap/continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "@uniswap/continuous-clearing-auction/test/utils/AuctionStepsBuilder.sol";
import {
    ContinuousClearingAuctionFactory
} from "@uniswap/continuous-clearing-auction/src/ContinuousClearingAuctionFactory.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {SaltGenerator} from "test/saltGenerator/LauncherSaltGenerator.sol";
import {Distribution} from "src/types/Distribution.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";

contract AdvancedLBPStrategyFactoryTest is Test {
    using AuctionStepsBuilder for bytes;

    uint128 constant TOTAL_SUPPLY = 1000e18;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    uint160 constant BEFORE_INITIALIZE_FLAG_MASK = 1 << 13;

    AdvancedLBPStrategyFactory public factory;
    MockERC20 token;
    LiquidityLauncher liquidityLauncher;
    ContinuousClearingAuctionFactory initializerFactory;
    MigratorParameters migratorParams;
    bytes auctionParams;

    function setUp() public {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), 23097193);
        factory = new AdvancedLBPStrategyFactory(IPositionManager(POSITION_MANAGER), IPoolManager(POOL_MANAGER));
        liquidityLauncher = new LiquidityLauncher(IAllowanceTransfer(PERMIT2));
        token = new MockERC20("Test Token", "TEST", TOTAL_SUPPLY, address(liquidityLauncher));
        initializerFactory = new ContinuousClearingAuctionFactory();

        migratorParams = MigratorParameters({
            currency: address(0),
            poolLPFee: 500,
            poolTickSpacing: 60,
            positionRecipient: address(3),
            migrationBlock: uint64(block.number + 101),
            initializerFactory: address(initializerFactory),
            tokenSplit: 5000,
            sweepBlock: uint64(block.number + 102),
            operator: address(this),
            maxCurrencyAmountForLP: type(uint128).max
        });

        auctionParams = abi.encode(
            AuctionParameters({
                currency: address(0), // ETH
                tokensRecipient: makeAddr("tokensRecipient"), // Some valid address
                fundsRecipient: address(1), // Some valid address
                startBlock: uint64(block.number),
                endBlock: uint64(block.number + 100),
                claimBlock: uint64(block.number + 100),
                tickSpacing: 1 << 96, // Valid tick spacing for auctions
                validationHook: address(0), // No validation hook
                floorPrice: 1 << 96, // 1:1 ratio
                requiredCurrencyRaised: 0,
                auctionStepsData: AuctionStepsBuilder.init().addStep(100e3, 100)
            })
        );
    }

    function test_initializeDistribution_succeeds() public {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(AdvancedLBPStrategy).creationCode,
                abi.encode(
                    token,
                    uint128(TOTAL_SUPPLY),
                    migratorParams,
                    auctionParams,
                    POSITION_MANAGER,
                    POOL_MANAGER,
                    true,
                    true
                )
            )
        );
        address poolMask = address(BEFORE_INITIALIZE_FLAG_MASK);
        bytes32 topLevelSalt = new SaltGenerator().withInitCodeHash(initCodeHash).withMask(poolMask)
            .withMsgSender(address(this)).withTokenLauncher(address(liquidityLauncher))
            .withStrategyFactoryAddress(address(factory)).generate();

        address expectedAddress = factory.getAddress(
            address(token),
            TOTAL_SUPPLY,
            abi.encode(migratorParams, auctionParams, true, true),
            keccak256(abi.encode(address(this), topLevelSalt)),
            address(liquidityLauncher)
        );

        Distribution memory distribution = Distribution({
            strategy: address(factory),
            amount: TOTAL_SUPPLY,
            configData: abi.encode(migratorParams, auctionParams, true, true)
        });

        AdvancedLBPStrategy lbp = AdvancedLBPStrategy(
            payable(address(liquidityLauncher.distributeToken(address(token), distribution, false, topLevelSalt)))
        );

        assertEq(address(lbp), expectedAddress);
        assertEq(lbp.totalSupply(), TOTAL_SUPPLY);
        assertEq(lbp.token(), address(token));
        assertEq(address(lbp.positionManager()), POSITION_MANAGER);
        assertEq(address(AdvancedLBPStrategy(payable(address(lbp))).poolManager()), POOL_MANAGER);
        assertEq(lbp.positionRecipient(), address(3));
        assertEq(lbp.migrationBlock(), block.number + 101);
        assertEq(lbp.poolLPFee(), 500);
        assertEq(lbp.poolTickSpacing(), 60);
        assertEq(lbp.initializerParameters(), auctionParams);
    }

    function test_getLBPAddress_succeeds() public {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(AdvancedLBPStrategy).creationCode,
                abi.encode(
                    token,
                    uint128(TOTAL_SUPPLY),
                    migratorParams,
                    auctionParams,
                    POSITION_MANAGER,
                    POOL_MANAGER,
                    true,
                    true
                )
            )
        );
        address poolMask = address(BEFORE_INITIALIZE_FLAG_MASK);
        bytes32 topLevelSalt = new SaltGenerator().withInitCodeHash(initCodeHash).withMask(poolMask)
            .withMsgSender(address(this)).withTokenLauncher(address(liquidityLauncher))
            .withStrategyFactoryAddress(address(factory)).generate();

        address lbpAddress = factory.getAddress(
            address(token),
            TOTAL_SUPPLY,
            abi.encode(migratorParams, auctionParams, true, true),
            keccak256(abi.encode(address(this), topLevelSalt)),
            address(liquidityLauncher)
        );

        Distribution memory distribution = Distribution({
            strategy: address(factory),
            amount: TOTAL_SUPPLY,
            configData: abi.encode(migratorParams, auctionParams, true, true)
        });

        assertEq(
            lbpAddress,
            address(
                payable(address(liquidityLauncher.distributeToken(address(token), distribution, false, topLevelSalt)))
            )
        );
    }
}
