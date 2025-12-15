// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LBPStrategyBasicFactory} from "../../src/distributionStrategies/LBPStrategyBasicFactory.sol";
import {LBPStrategyBasic} from "../../src/distributionContracts/LBPStrategyBasic.sol";
import {LiquidityLauncher} from "../../src/LiquidityLauncher.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MigratorParameters} from "../../src/types/MigratorParameters.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookBasic} from "../../src/utils/HookBasic.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "continuous-clearing-auction/test/utils/AuctionStepsBuilder.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/src/ContinuousClearingAuctionFactory.sol";

contract LBPStrategyBasicFactoryTest is Test {
    using AuctionStepsBuilder for bytes;

    uint128 constant TOTAL_SUPPLY = 1000e18;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    LBPStrategyBasicFactory public factory;
    MockERC20 token;
    LiquidityLauncher liquidityLauncher;
    ContinuousClearingAuctionFactory auctionFactory;
    MigratorParameters migratorParams;
    bytes auctionParams;

    function setUp() public {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), 23097193);
        factory = new LBPStrategyBasicFactory(IPositionManager(POSITION_MANAGER), IPoolManager(POOL_MANAGER));
        liquidityLauncher = new LiquidityLauncher(IAllowanceTransfer(PERMIT2));
        token = new MockERC20("Test Token", "TEST", TOTAL_SUPPLY, address(liquidityLauncher));
        auctionFactory = new ContinuousClearingAuctionFactory();

        migratorParams = MigratorParameters({
            currency: address(0),
            poolLPFee: 500,
            poolTickSpacing: 60,
            positionRecipient: address(3),
            migrationBlock: uint64(block.number + 101),
            auctionFactory: address(auctionFactory),
            tokenSplitToAuction: 5000,
            sweepBlock: uint64(block.number + 102),
            operator: address(this)
        });

        auctionParams = abi.encode(
            AuctionParameters({
                currency: address(0), // ETH
                tokensRecipient: makeAddr("tokensRecipient"), // Some valid address
                fundsRecipient: address(1), // Some valid address
                startBlock: uint64(block.number),
                endBlock: uint64(block.number + 100),
                claimBlock: uint64(block.number + 100),
                tickSpacing: 1e6, // Valid tick spacing for auctions
                validationHook: address(0), // No validation hook
                floorPrice: 1e6, // 1 ETH as floor price
                requiredCurrencyRaised: 0,
                auctionStepsData: AuctionStepsBuilder.init().addStep(100e3, 100)
            })
        );
    }

    function test_initializeDistribution_succeeds() public {
        // mined a salt that when hashed with address(this), gives a valid hook address with beforeInitialize flag set to true
        // uncomment to see the initCodeHash
        // bytes32 initCodeHash = keccak256(
        //     abi.encodePacked(
        //         type(LBPStrategyBasic).creationCode,
        //         abi.encode(
        //             address(token),
        //             TOTAL_SUPPLY,
        //             migratorParams,
        //             auctionParams,
        //             IPositionManager(POSITION_MANAGER),
        //             IPoolManager(POOL_MANAGER),
        //             true,
        //             true
        //         )
        //     )
        // );
        LBPStrategyBasic lbp = LBPStrategyBasic(
            payable(address(
                    factory.initializeDistribution(
                        address(token),
                        TOTAL_SUPPLY,
                        abi.encode(migratorParams, auctionParams, true, true),
                        0x7fa9385be102ac3eac297483dd6233d62b3e1496899124c89fcde98ebe6d25cf
                    )
                ))
        );

        assertEq(lbp.totalSupply(), TOTAL_SUPPLY);
        assertEq(lbp.token(), address(token));
        assertEq(address(lbp.positionManager()), POSITION_MANAGER);
        assertEq(address(LBPStrategyBasic(payable(address(lbp))).poolManager()), POOL_MANAGER);
        assertEq(lbp.positionRecipient(), address(3));
        assertEq(lbp.migrationBlock(), block.number + 101);
        assertEq(lbp.poolLPFee(), 500);
        assertEq(lbp.poolTickSpacing(), 60);
        assertEq(lbp.auctionParameters(), auctionParams);
    }

    function test_getLBPAddress_succeeds() public {
        bytes32 salt = 0x7fa9385be102ac3eac297483dd6233d62b3e1496899124c89fcde98ebe6d25cf;
        address lbpAddress = factory.getLBPAddress(
            address(token), TOTAL_SUPPLY, abi.encode(migratorParams, auctionParams, true, true), salt, address(this)
        );
        assertEq(
            lbpAddress,
            address(
                factory.initializeDistribution(
                    address(token), TOTAL_SUPPLY, abi.encode(migratorParams, auctionParams, true, true), salt
                )
            )
        );
    }

    function test_getLBPAddress_deterministicSender() public {
        bytes32 salt = 0x7fa9385be102ac3eac297483dd6233d62b3e1496899124c89fcde98ebe6d25cf;
        address sender1 = address(1);
        address sender2 = address(2);
        vm.prank(sender1);
        address lbpAddress1 = factory.getLBPAddress(
            address(token), TOTAL_SUPPLY, abi.encode(migratorParams, auctionParams, true, true), salt, sender1
        );
        vm.prank(sender2);
        address lbpAddress2 = factory.getLBPAddress(
            address(token), TOTAL_SUPPLY, abi.encode(migratorParams, auctionParams, true, true), salt, sender2
        );
        assertNotEq(lbpAddress1, lbpAddress2);
    }
}
