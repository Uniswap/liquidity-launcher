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

contract LBPStrategyBasicSetupTest is LBPStrategyBasicTestBase {
    using AuctionStepsBuilder for bytes;
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
            true,
            true
        );

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.TokenSplitTooHigh.selector, tokenSplitValue, maxTokenSplit)
        );

        new LBPStrategyBasicNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            params,
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidTickSpacing() public {
        // Test too low
        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBasic.InvalidTickSpacing.selector,
                TickMath.MIN_TICK_SPACING - 1,
                TickMath.MIN_TICK_SPACING,
                TickMath.MAX_TICK_SPACING
            )
        );

        new LBPStrategyBasicNoValidation(
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
                true,
                true
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // Test too high
        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBasic.InvalidTickSpacing.selector,
                TickMath.MAX_TICK_SPACING + 1,
                TickMath.MIN_TICK_SPACING,
                TickMath.MAX_TICK_SPACING
            )
        );

        new LBPStrategyBasicNoValidation(
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
                true,
                true
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBasic.InvalidFee.selector, LPFeeLibrary.MAX_LP_FEE + 1, LPFeeLibrary.MAX_LP_FEE
            )
        );

        new LBPStrategyBasicNoValidation(
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
                true,
                true
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidPositionRecipient() public {
        address[3] memory invalidRecipients = [address(0), address(1), address(2)];

        for (uint256 i = 0; i < invalidRecipients.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBasic.InvalidPositionRecipient.selector, invalidRecipients[i])
            );

            new LBPStrategyBasicNoValidation(
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
                    true,
                    true
                ),
                auctionParams,
                IPositionManager(POSITION_MANAGER),
                IPoolManager(POOL_MANAGER)
            );
        }
    }

    function test_setUp_revertsWithInvalidToken() public {
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.InvalidToken.selector, address(token)));

        new LBPStrategyBasicNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(
                address(token),
                500,
                100,
                DEFAULT_TOKEN_SPLIT,
                address(3),
                uint64(block.number + 500),
                uint64(block.number + 1_000),
                address(this),
                true,
                true
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.InvalidToken.selector, address(0)));

        new LBPStrategyBasicNoValidation(
            address(0),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(
                address(token),
                500,
                100,
                DEFAULT_TOKEN_SPLIT,
                address(3),
                uint64(block.number + 500),
                uint64(block.number + 1_000),
                address(this),
                true,
                true
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidFundsRecipient() public {
        bytes memory auctionStepsData = AuctionStepsBuilder.init().addStep(100e3, 100);

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.InvalidFundsRecipient.selector, address(2), address(1))
        );
        new LBPStrategyBasicNoValidation(
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
                true,
                true
            ),
            abi.encode(
                AuctionParameters({
                    currency: address(0), // ETH
                    tokensRecipient: makeAddr("tokensRecipient"), // Some valid address
                    fundsRecipient: address(2),
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
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_reverts_auctionParametersEncodedImproperly() public {
        vm.expectRevert();
        new LBPStrategyBasicNoValidation(
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
                true,
                true
            ),
            "",
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    // ============ Token Reception Tests ============

    function test_onTokenReceived_revertsWithInvalidAmountReceived() public {
        vm.prank(address(tokenLauncher));
        ERC20(token).transfer(address(lbp), DEFAULT_TOTAL_SUPPLY - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDistributionContract.InvalidAmountReceived.selector, DEFAULT_TOTAL_SUPPLY, DEFAULT_TOTAL_SUPPLY - 1
            )
        );
        lbp.onTokensReceived();
    }

    function test_onTokenReceived_succeeds() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), DEFAULT_TOTAL_SUPPLY);
        console2.logBytes(auctionParams);
        console2.logBytes(lbp.auctionParameters());
        lbp.onTokensReceived();

        // Verify auction is created
        assertNotEq(address(lbp.auction()), address(0));

        // Verify token distribution
        uint256 expectedAuctionAmount = DEFAULT_TOTAL_SUPPLY * DEFAULT_TOKEN_SPLIT / 1e7;
        assertEq(token.balanceOf(address(lbp.auction())), expectedAuctionAmount);
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

        // Skip if auction amount would be 0
        uint256 auctionAmount = uint256(totalSupply) * uint256(tokenSplit) / 1e7;
        vm.assume(auctionAmount > 0);

        setupWithSupplyAndTokenSplit(totalSupply, tokenSplit, address(0));

        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived();

        uint256 expectedAuctionAmount = uint128(uint256(totalSupply) * uint256(tokenSplit) / 1e7);
        assertEq(token.balanceOf(address(lbp.auction())), expectedAuctionAmount);
        assertEq(token.balanceOf(address(lbp)), totalSupply - expectedAuctionAmount);
    }

    function test_fuzz_onTokenReceived_succeeds(uint128 totalSupply) public {
        vm.assume(totalSupply > 1);
        setupWithSupply(totalSupply);

        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived();

        // Verify auction is created
        assertNotEq(address(lbp.auction()), address(0));

        // Verify token distribution
        uint256 expectedAuctionAmount = uint128(uint256(totalSupply) * uint256(DEFAULT_TOKEN_SPLIT) / 1e7);
        assertEq(token.balanceOf(address(lbp.auction())), expectedAuctionAmount);
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
        address operator
    ) public {
        uint24 maxTokenSplit = TokenDistribution.MAX_TOKEN_SPLIT;
        AuctionParameters memory auctionParameters = abi.decode(auctionParams, (AuctionParameters));
        if (sweepBlock <= migrationBlock) {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBasic.InvalidSweepBlock.selector, sweepBlock, migrationBlock)
            );
        }
        // Test token split validation
        else if (tokenSplit >= maxTokenSplit) {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBasic.TokenSplitTooHigh.selector, tokenSplit, maxTokenSplit)
            );
        }
        // Test tick spacing validation
        else if (poolTickSpacing < TickMath.MIN_TICK_SPACING || poolTickSpacing > TickMath.MAX_TICK_SPACING) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ILBPStrategyBasic.InvalidTickSpacing.selector,
                    poolTickSpacing,
                    TickMath.MIN_TICK_SPACING,
                    TickMath.MAX_TICK_SPACING
                )
            );
        }
        // Test fee validation
        else if (poolLPFee > LPFeeLibrary.MAX_LP_FEE) {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBasic.InvalidFee.selector, poolLPFee, LPFeeLibrary.MAX_LP_FEE)
            );
        }
        // Test position recipient validation
        else if (positionRecipient == address(0) || positionRecipient == address(1) || positionRecipient == address(2))
        {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBasic.InvalidPositionRecipient.selector, positionRecipient)
            );
        } else if (FullMath.mulDiv(totalSupply, tokenSplit, maxTokenSplit) == 0) {
            vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.AuctionSupplyIsZero.selector));
        } else if (auctionParameters.endBlock >= migrationBlock) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    ILBPStrategyBasic.InvalidEndBlock.selector, auctionParameters.endBlock, migrationBlock
                )
            );
        }

        // Should succeed with valid params
        new LBPStrategyBasicNoValidation(
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
                true,
                true
            ),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }
}
