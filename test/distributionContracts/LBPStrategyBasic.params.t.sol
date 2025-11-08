// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./base/LBPStrategyBasicTestBase.sol";
import {ILBPStrategyBasic} from "../../src/interfaces/ILBPStrategyBasic.sol";
import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ERC20} from "@openzeppelin-latest/contracts/token/ERC20/ERC20.sol";
import {HookBasic} from "../../src/utils/HookBasic.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";
import {AuctionStepsBuilder} from "twap-auction/test/utils/AuctionStepsBuilder.sol";
import {LBPStrategyBasic} from "../../src/distributionContracts/LBPStrategyBasic.sol";
import {AuctionParameters} from "twap-auction/src/interfaces/IAuction.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TokenDistribution} from "../../src/libraries/TokenDistribution.sol";
import {TokenPricing} from "../../src/libraries/TokenPricing.sol";
import {Math} from "@openzeppelin-latest/contracts/utils/math/Math.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {console2} from "forge-std/console2.sol";
import {Checkpoint, ValueX7} from "twap-auction/src/libraries/CheckpointLib.sol";

contract LBPStrategyBasicParamsTest is LBPStrategyBasicTestBase {
    using AuctionStepsBuilder for bytes;
    using TokenDistribution for uint128;
    // ============ Constructor Validation Tests ============

    function test_fuzz_setUp_params(uint256 clearingPrice) public {
        token = MockERC20(0xA27EC0006e59f245217Ff08CD52A7E8b169E62D2);
        implToken = new MockERC20("Test Token", "TEST", 1_820_000_000e18, address(tokenLauncher));
        vm.etch(0xA27EC0006e59f245217Ff08CD52A7E8b169E62D2, address(implToken).code);
        deal(address(token), address(tokenLauncher), 1_820_000_000e18);
        address testOperator = makeAddr("testOperator");

        MigratorParameters memory params = createMigratorParams(
            address(0),
            500,
            10,
            0.85e7,
            address(3),
            uint64(23791222 + 129600 + 7200 + 3600 + 3600 + 7200 + 7200 + 7200 + 1 + 1),
            uint64(23791222 + 129600 + 7200 + 3600 + 3600 + 7200 + 7200 + 7200 + 1 + 1 + 7200),
            testOperator,
            false,
            false
        );

        bytes memory auctionStepsData = AuctionStepsBuilder.init().addStep(0, 129600).addStep(347, 7200)
            .addStep(0, 3600).addStep(138, 3600).addStep(138, 7200).addStep(138, 7200).addStep(138, 7200)
            .addStep(4_024_000, 1);

        bytes memory auctionParams = abi.encode(
            AuctionParameters({
                currency: address(0),
                tokensRecipient: address(0xBFdF6a252164343f9645A61FA3B7650f2214C69b),
                fundsRecipient: address(1),
                startBlock: uint64(23791222),
                endBlock: uint64(23791222 + 129600 + 7200 + 3600 + 3600 + 7200 + 7200 + 7200 + 1),
                claimBlock: uint64(23791222 + 129600 + 7200 + 3600 + 3600 + 7200 + 7200 + 7200 + 1),
                tickSpacing: 6_699_440_212_603_230_000_000,
                validationHook: address(0),
                floorPrice: 669_944_021_260_323_000_000_000,
                requiredCurrencyRaised: 0,
                auctionStepsData: auctionStepsData
            })
        );

        impl = new LBPStrategyBasicNoValidation(
            address(0xA27EC0006e59f245217Ff08CD52A7E8b169E62D2),
            1_820_000_000e18,
            params,
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        vm.etch(address(lbp), address(impl).code);

        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), 1_820_000_000e18);
        console2.logBytes(auctionParams);
        console2.logBytes(lbp.auctionParameters());
        lbp.onTokensReceived();

        uint128 tokenAmount = 1_820_000_000e18 * 0.85e7 / 1e7;

        clearingPrice = uint256(bound(clearingPrice, 2 ** 32 + 1, 2 ** 110));

        // Verify auction is created
        assertNotEq(address(lbp.auction()), address(0));

        // Verify token distribution
        uint256 expectedAuctionAmount = 1_820_000_000e18 * 0.85e7 / 1e7;
        assertEq(token.balanceOf(address(lbp.auction())), expectedAuctionAmount);
        assertEq(token.balanceOf(address(lbp)), 1_820_000_000e18 - expectedAuctionAmount);

        mockAuctionClearingPrice(lbp, clearingPrice);
        mockAuctionEndBlock(lbp, uint64(block.number - 1));
        mockCurrencyRaised(lbp, FullMath.mulDiv(tokenAmount, clearingPrice, 2 ** 96));
        deal(address(lbp), FullMath.mulDiv(tokenAmount, clearingPrice, 2 ** 96));

        mockAuctionCheckpoint(
            lbp,
            Checkpoint({
                clearingPrice: clearingPrice,
                currencyRaisedAtClearingPriceQ96_X7: ValueX7.wrap(FullMath.mulDiv(tokenAmount, clearingPrice, 2 ** 96)),
                cumulativeMpsPerPrice: 0,
                cumulativeMps: 0,
                prev: 0,
                next: type(uint64).max
            })
        );

        // Take balance snapshot
        BalanceSnapshot memory before =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, address(3));

        vm.roll(lbp.migrationBlock());

        lbp.migrate();

        // Take balance snapshot after
        BalanceSnapshot memory afterMigration =
            takeBalanceSnapshot(address(token), address(0), POSITION_MANAGER, POOL_MANAGER, address(3));

        // Verify main position
        assertPositionCreated(
            IPositionManager(POSITION_MANAGER),
            nextTokenId,
            address(0),
            address(token),
            500, // poolLPFee
            10, // poolTickSpacing
            TickMath.MIN_TICK / 10 * 10,
            TickMath.MAX_TICK / 10 * 10
        );

        // Verify one-sided position is not created
        assertPositionNotCreated(IPositionManager(POSITION_MANAGER), nextTokenId + 1);

        // Verify balances
        assertBalancesAfterMigration(before, afterMigration);

        uint256 operatorCurrencyBalanceBefore = Currency.wrap(address(0)).balanceOf(lbp.operator());
        vm.roll(lbp.sweepBlock());
        vm.prank(lbp.operator());
        lbp.sweepCurrency();
        vm.prank(lbp.operator());
        lbp.sweepToken();
        assertEq(Currency.wrap(address(0)).balanceOf(address(lbp)), 0);
        assertGt(Currency.wrap(address(0)).balanceOf(lbp.operator()), operatorCurrencyBalanceBefore);

        assertEq(Currency.wrap(address(token)).balanceOf(address(lbp)), 0);
        assertLe(Currency.wrap(address(token)).balanceOf(lbp.operator()), DUST_AMOUNT);
    }

    function aztecTickNumberToPriceX96(uint256 tickNumber) internal pure returns (uint256) {
        return 669_944_021_260_323_000_000_000 + (tickNumber - 1) * 6_699_440_212_603_230_000_000;
    }
}
