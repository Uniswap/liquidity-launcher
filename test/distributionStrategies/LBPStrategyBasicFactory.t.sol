// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LBPStrategyBasicFactory} from "../../src/distributionStrategies/LBPStrategyBasicFactory.sol";
import {LBPStrategyBasic} from "../../src/distributionContracts/LBPStrategyBasic.sol";
import {TokenLauncher} from "../../src/TokenLauncher.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {MigratorParameters} from "../../src/types/MigratorParams.sol";
import {MockDistributionStrategy} from "../mocks/MockDistributionStrategy.sol";
import {LBPStrategyBasic} from "../../src/distributionContracts/LBPStrategyBasic.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {HookBasic} from "../../src/utils/HookBasic.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";
import {AuctionStepsBuilder} from "twap-auction/test/utils/AuctionStepsBuilder.sol";
//import "forge-std/console2.sol";

contract LBPStrategyBasicFactoryTest is Test {
    using AuctionStepsBuilder for bytes;

    uint128 constant TOTAL_SUPPLY = 1000e18;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    LBPStrategyBasicFactory public factory;
    MockERC20 token;
    TokenLauncher tokenLauncher;
    MockDistributionStrategy mock;
    MigratorParameters migratorParams;
    AuctionParameters auctionParams;

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_URL"), 23097193);
        factory =
            new LBPStrategyBasicFactory(IPositionManager(POSITION_MANAGER), IPoolManager(POOL_MANAGER), IWETH9(WETH9));
        tokenLauncher = new TokenLauncher(IAllowanceTransfer(PERMIT2));
        token = new MockERC20("Test Token", "TEST", TOTAL_SUPPLY, address(tokenLauncher));
        mock = new MockDistributionStrategy();

        migratorParams = MigratorParameters({
            currency: address(0),
            poolLPFee: 500,
            poolTickSpacing: 60,
            positionRecipient: address(3),
            migrationBlock: uint64(block.number + 1),
            tokenSplitToAuction: 5000
        });

        auctionParams = AuctionParameters({
            currency: address(0), // ETH
            tokensRecipient: makeAddr("tokensRecipient"), // Some valid address
            fundsRecipient: makeAddr("fundsRecipient"), // Some valid address
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            claimBlock: uint64(block.number + 100),
            tickSpacing: 1e6, // Valid tick spacing for auctions
            validationHook: address(0), // No validation hook
            floorPrice: 1e6, // 1 ETH as floor price
            auctionStepsData: AuctionStepsBuilder.init().addStep(100e3, 100)
        });
    }

    function test_initializeDistribution_succeeds() public {
        // mined a salt that when hashed with address(this), gives a valid hook address with beforeInitialize flag set to true
        // bytes32 initCodeHash = keccak256(
        //     abi.encodePacked(
        //         type(LBPStrategyBasic).creationCode,
        //         abi.encode(
        //             address(token),
        //             TOTAL_SUPPLY,
        //             migratorParams,
        //             bytes(""),
        //             IPositionManager(POSITION_MANAGER),
        //             IPoolManager(POOL_MANAGER),
        //             IWETH9(WETH9)
        //         )
        //     )
        // );
        // console2.logBytes32(initCodeHash);
        LBPStrategyBasic lbp = LBPStrategyBasic(
            address(
                factory.initializeDistribution(
                    address(token),
                    TOTAL_SUPPLY,
                    abi.encode(
                        migratorParams,
                        auctionParams,
                        IPositionManager(POSITION_MANAGER),
                        IPoolManager(POOL_MANAGER),
                        IWETH9(WETH9)
                    ),
                    0x7fa9385be102ac3eac297483dd6233d62b3e1496f04223c251e9028bcc4733ff
                )
            )
        );

        assertEq(lbp.totalSupply(), TOTAL_SUPPLY);
        assertEq(lbp.token(), address(token));
        assertEq(address(lbp.positionManager()), POSITION_MANAGER);
        assertEq(address(lbp.poolManager()), POOL_MANAGER);
        assertEq(lbp.positionRecipient(), address(3));
        assertEq(lbp.migrationBlock(), block.number + 1);
        assertEq(lbp.poolLPFee(), 500);
        assertEq(lbp.poolTickSpacing(), 60);
    }

    function test_getLBPAddress_succeeds() public {
        bytes32 salt = 0x7fa9385be102ac3eac297483dd6233d62b3e1496f04223c251e9028bcc4733ff;
        address lbpAddress = factory.getLBPAddress(
            address(token),
            TOTAL_SUPPLY,
            abi.encode(
                migratorParams, bytes(""), IPositionManager(POSITION_MANAGER), IPoolManager(POOL_MANAGER), IWETH9(WETH9)
            ),
            keccak256(abi.encode(address(this), salt))
        );
        assertEq(
            lbpAddress,
            address(
                factory.initializeDistribution(
                    address(token),
                    TOTAL_SUPPLY,
                    abi.encode(
                        migratorParams,
                        auctionParams,
                        IPositionManager(POSITION_MANAGER),
                        IPoolManager(POOL_MANAGER),
                        IWETH9(WETH9)
                    ),
                    salt
                )
            )
        );
    }
}
