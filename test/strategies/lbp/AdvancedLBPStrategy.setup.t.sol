// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./base/AdvancedLBPStrategyTestBase.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SelfInitializerHook} from "periphery/hooks/SelfInitializerHook.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "continuous-clearing-auction/test/utils/AuctionStepsBuilder.sol";
import {AdvancedLBPStrategy} from "@lbp/strategies/AdvancedLBPStrategy.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TokenDistribution} from "src/libraries/TokenDistribution.sol";
import {TokenPricing} from "src/libraries/TokenPricing.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {ConstantsLib} from "continuous-clearing-auction/src/libraries/ConstantsLib.sol";

contract AdvancedLBPStrategySetupTest is AdvancedLBPStrategyTestBase {
    using AuctionStepsBuilder for bytes;
    using TokenDistribution for uint128;
    // ============ Constructor Validation Tests ============

    function test_setUp_revertsWithTokenSplitTooHigh() public {
        uint24 maxTokenSplit = TokenDistribution.MAX_TOKEN_SPLIT;
        uint24 tokenSplitValue = maxTokenSplit + 1;

        MigratorParameters memory params = createMigratorParams(
            address(0),
            500,
            100,
            tokenSplitValue,
            address(3),
            uint64(block.number + 500),
            uint64(block.number + 1_000),
            address(this),
            DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP
        );

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.TokenSplitTooHigh.selector, tokenSplitValue, maxTokenSplit)
        );

        new AdvancedLBPStrategyNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            params,
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            true,
            true
        );
    }

    function test_setUp_revertsWithInvalidTickSpacing() public {
        // Test too low
        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.InvalidTickSpacing.selector,
                TickMath.MIN_TICK_SPACING - 1,
                TickMath.MIN_TICK_SPACING,
                TickMath.MAX_TICK_SPACING
            )
        );

        new AdvancedLBPStrategyNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(
                address(0),
                500,
                TickMath.MIN_TICK_SPACING - 1,
                DEFAULT_TOKEN_SPLIT,
                address(3),
                uint64(block.number + 500),
                uint64(block.number + 1_000),
                address(this),
                DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            true,
            true
        );

        // Test too high
        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.InvalidTickSpacing.selector,
                TickMath.MAX_TICK_SPACING + 1,
                TickMath.MIN_TICK_SPACING,
                TickMath.MAX_TICK_SPACING
            )
        );

        new AdvancedLBPStrategyNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(
                address(0),
                500,
                TickMath.MAX_TICK_SPACING + 1,
                DEFAULT_TOKEN_SPLIT,
                address(3),
                uint64(block.number + 500),
                uint64(block.number + 1_000),
                address(this),
                DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            true,
            true
        );
    }

    function test_setUp_revertsWithInvalidFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.InvalidFee.selector, LPFeeLibrary.MAX_LP_FEE + 1, LPFeeLibrary.MAX_LP_FEE
            )
        );

        new AdvancedLBPStrategyNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(
                address(0),
                LPFeeLibrary.MAX_LP_FEE + 1,
                100,
                DEFAULT_TOKEN_SPLIT,
                address(3),
                uint64(block.number + 500),
                uint64(block.number + 1_000),
                address(this),
                DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            true,
            true
        );
    }

    function test_setUp_revertsWithInvalidPositionRecipient() public {
        address[3] memory invalidRecipients = [address(0), address(1), address(2)];

        for (uint256 i = 0; i < invalidRecipients.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBase.InvalidPositionRecipient.selector, invalidRecipients[i])
            );

            new AdvancedLBPStrategyNoValidation(
                address(token),
                DEFAULT_TOTAL_SUPPLY,
                createMigratorParams(
                    address(0),
                    500,
                    100,
                    DEFAULT_TOKEN_SPLIT,
                    invalidRecipients[i],
                    uint64(block.number + 500),
                    uint64(block.number + 1_000),
                    address(this),
                    DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP
                ),
                auctionParams,
                IPositionManager(POSITION_MANAGER),
                IPoolManager(POOL_MANAGER),
                true,
                true
            );
        }
    }

    function test_setUp_revertsWithInvalidFundsRecipient() public {
        bytes memory auctionStepsData = AuctionStepsBuilder.init().addStep(100e3, 100);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBase.InvalidFundsRecipient.selector, address(2), address(1)));
        new AdvancedLBPStrategyNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(
                address(0),
                500,
                100,
                DEFAULT_TOKEN_SPLIT,
                address(3),
                uint64(block.number + 500),
                uint64(block.number + 1000),
                address(this),
                DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP
            ),
            abi.encode(
                AuctionParameters({
                    currency: address(0), // ETH
                    tokensRecipient: makeAddr("tokensRecipient"), // Some valid address
                    fundsRecipient: address(2), // invalid funds recipient
                    startBlock: uint64(block.number),
                    endBlock: uint64(block.number + 100),
                    claimBlock: uint64(block.number + 100),
                    tickSpacing: 20,
                    validationHook: address(0), // No validation hook
                    floorPrice: 1,
                    requiredCurrencyRaised: 0,
                    auctionStepsData: auctionStepsData
                })
            ),
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            true,
            true
        );
    }

    function test_setUp_revertsWithInvalidCurrency() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBase.InvalidCurrency.selector, address(0), address(1)));
        new AdvancedLBPStrategyNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(
                address(1),
                500,
                100,
                DEFAULT_TOKEN_SPLIT,
                address(3),
                uint64(block.number + 500),
                uint64(block.number + 1000),
                address(this),
                DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP
            ), // currency is address(1)
            auctionParams, // currency is address(0)
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            true,
            true
        );
    }

    function test_setUp_reverts_initializerParametersEncodedImproperly() public {
        vm.expectRevert();
        new AdvancedLBPStrategyNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(
                address(0),
                500,
                100,
                DEFAULT_TOKEN_SPLIT,
                address(3),
                uint64(block.number + 500),
                uint64(block.number + 1000),
                address(this),
                DEFAULT_MAX_CURRENCY_AMOUNT_FOR_LP
            ),
            "",
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            true,
            true
        );
    }

    // ============ Token Reception Tests ============

    function test_onTokenReceived_revertsWithInvalidAmountReceived() public {
        vm.prank(address(liquidityLauncher));
        ERC20(token).transfer(address(lbp), DEFAULT_TOTAL_SUPPLY - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDistributionContract.InvalidAmountReceived.selector, DEFAULT_TOTAL_SUPPLY, DEFAULT_TOTAL_SUPPLY - 1
            )
        );
        lbp.onTokensReceived();
    }

    function test_onTokenReceived_succeeds() public {
        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), DEFAULT_TOTAL_SUPPLY);
        console2.logBytes(auctionParams);
        console2.logBytes(lbp.initializerParameters());
        lbp.onTokensReceived();

        // Verify auction is created
        assertNotEq(address(lbp.initializer()), address(0));

        // Verify token distribution
        uint256 expectedAuctionAmount = DEFAULT_TOTAL_SUPPLY * DEFAULT_TOKEN_SPLIT / 1e7;
        assertEq(token.balanceOf(address(lbp.initializer())), expectedAuctionAmount);
        assertEq(token.balanceOf(address(lbp)), DEFAULT_TOTAL_SUPPLY - expectedAuctionAmount);
    }

    // only the hook can initialize the pool
    function test_initializeFailsIfNotHook() public {
        setupWithSupply(DEFAULT_TOTAL_SUPPLY);
        // (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = lbp.key();
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: lbp.poolLPFee(),
            tickSpacing: lbp.poolTickSpacing(),
            hooks: IHooks(address(lbp))
        });
        vm.expectRevert();
        IPoolManager(POOL_MANAGER).initialize(poolKey, 1);
    }

    // ============ Fuzzed Tests ============

    function test_fuzz_totalSupplyAndTokenSplit(uint128 totalSupply, uint24 tokenSplit) public {
        tokenSplit = uint24(bound(tokenSplit, 1, 1e7 - 1));
        vm.assume(totalSupply.calculateReserveSupply(tokenSplit) <= ConstantsLib.MAX_TOTAL_SUPPLY);

        // Skip if auction amount would be 0
        uint256 auctionAmount = (uint256(totalSupply) * uint256(tokenSplit)) / 1e7;
        vm.assume(auctionAmount > 0);
        vm.assume(auctionAmount <= ConstantsLib.MAX_TOTAL_SUPPLY);

        assertLe(auctionAmount, totalSupply, "auction amount is greater than total supply");

        setupWithSupplyAndTokenSplit(totalSupply, tokenSplit, address(0));

        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived();

        uint256 expectedAuctionAmount = uint128(uint256(totalSupply) * uint256(tokenSplit) / 1e7);
        assertEq(token.balanceOf(address(lbp.initializer())), expectedAuctionAmount);
        assertEq(token.balanceOf(address(lbp)), totalSupply - expectedAuctionAmount);
    }

    function test_fuzz_onTokenReceived_succeeds(uint128 totalSupply) public {
        vm.assume(totalSupply > 1);
        vm.assume(totalSupply.calculateReserveSupply(DEFAULT_TOKEN_SPLIT) <= 1e30);
        setupWithSupply(totalSupply);

        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived();

        // Verify auction is created
        assertNotEq(address(lbp.initializer()), address(0));

        // Verify token distribution
        uint256 expectedAuctionAmount = uint128(uint256(totalSupply) * uint256(DEFAULT_TOKEN_SPLIT) / 1e7);
        assertEq(token.balanceOf(address(lbp.initializer())), expectedAuctionAmount);
        assertEq(token.balanceOf(address(lbp)), totalSupply - expectedAuctionAmount);
    }

    function test_fuzz_constructor_validation(
        uint128 totalSupply,
        uint24 poolLPFee,
        int24 poolTickSpacing,
        uint24 tokenSplit,
        address positionRecipient,
        uint64 sweepBlock,
        uint64 migrationBlock,
        address operator,
        uint128 maxCurrencyAmountForLP
    ) public {
        uint24 maxTokenSplit = TokenDistribution.MAX_TOKEN_SPLIT;
        AuctionParameters memory initializerParameters = abi.decode(auctionParams, (AuctionParameters));
        if (sweepBlock <= migrationBlock) {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBase.InvalidSweepBlock.selector, sweepBlock, migrationBlock)
            );
        }
        // Test token split validation
        else if (tokenSplit >= maxTokenSplit) {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBase.TokenSplitTooHigh.selector, tokenSplit, maxTokenSplit)
            );
        }
        // Test tick spacing validation
        else if (poolTickSpacing < TickMath.MIN_TICK_SPACING || poolTickSpacing > TickMath.MAX_TICK_SPACING) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ILBPStrategyBase.InvalidTickSpacing.selector,
                    poolTickSpacing,
                    TickMath.MIN_TICK_SPACING,
                    TickMath.MAX_TICK_SPACING
                )
            );
        }
        // Test fee validation
        else if (poolLPFee > LPFeeLibrary.MAX_LP_FEE) {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBase.InvalidFee.selector, poolLPFee, LPFeeLibrary.MAX_LP_FEE)
            );
        }
        // Test position recipient validation
        else if (positionRecipient == address(0) || positionRecipient == address(1) || positionRecipient == address(2))
        {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBase.InvalidPositionRecipient.selector, positionRecipient)
            );
        } else if (FullMath.mulDiv(totalSupply, tokenSplit, maxTokenSplit) == 0) {
            vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBase.InitializerTokenSplitIsZero.selector));
        } else if (initializerParameters.endBlock >= migrationBlock) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ILBPStrategyBase.InvalidEndBlock.selector, initializerParameters.endBlock, migrationBlock
                )
            );
        }

        // Should succeed with valid params
        new AdvancedLBPStrategyNoValidation(
            address(token),
            totalSupply,
            createMigratorParams(
                address(0),
                poolLPFee,
                poolTickSpacing,
                tokenSplit,
                positionRecipient,
                migrationBlock,
                sweepBlock,
                operator,
                maxCurrencyAmountForLP
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER),
            true,
            true
        );
    }
}
