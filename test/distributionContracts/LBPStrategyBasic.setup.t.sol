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

contract LBPStrategyBasicSetupTest is LBPStrategyBasicTestBase {
    // ============ Constructor Validation Tests ============

    function test_setUp_revertsWithTokenSplitTooHigh() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.TokenSplitTooHigh.selector, DEFAULT_TOKEN_SPLIT + 1));

        new LBPStrategyBasicNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(address(0), 500, 100, DEFAULT_TOKEN_SPLIT + 1, address(3)),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidTickSpacing() public {
        // Test too low
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.InvalidTickSpacing.selector, TickMath.MIN_TICK_SPACING - 1)
        );

        new LBPStrategyBasicNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(address(0), 500, TickMath.MIN_TICK_SPACING - 1, DEFAULT_TOKEN_SPLIT, address(3)),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );

        // Test too high
        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBasic.InvalidTickSpacing.selector, TickMath.MAX_TICK_SPACING + 1)
        );

        new LBPStrategyBasicNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(address(0), 500, TickMath.MAX_TICK_SPACING + 1, DEFAULT_TOKEN_SPLIT, address(3)),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }

    function test_setUp_revertsWithInvalidFee() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidFee.selector, LPFeeLibrary.MAX_LP_FEE + 1));

        new LBPStrategyBasicNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(address(0), LPFeeLibrary.MAX_LP_FEE + 1, 100, DEFAULT_TOKEN_SPLIT, address(3)),
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
                createMigratorParams(address(0), 500, 100, DEFAULT_TOKEN_SPLIT, invalidRecipients[i]),
                auctionParams,
                IPositionManager(POSITION_MANAGER),
                IPoolManager(POOL_MANAGER)
            );
        }
    }

    function test_setUp_revertsWithInvalidTokenAndCurrency() public {
        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidTokenAndCurrency.selector, address(token)));

        new LBPStrategyBasicNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(address(token), 500, 100, DEFAULT_TOKEN_SPLIT, address(3)),
            auctionParams,
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
        uint256 expectedAuctionAmount = DEFAULT_TOTAL_SUPPLY * DEFAULT_TOKEN_SPLIT / 10_000;
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

    function test_fuzz_totalSupplyAndTokenSplit(uint128 totalSupply, uint16 tokenSplit) public {
        // Add bounds to fuzz parameters
        vm.assume(tokenSplit <= 5_000);
        vm.assume(totalSupply > 1);
        vm.assume(uint128(uint256(totalSupply) * uint256(tokenSplit) / 10_000) > 0);

        setupWithSupplyAndTokenSplit(totalSupply, tokenSplit);

        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived();

        uint256 expectedAuctionAmount = uint128(uint256(totalSupply) * uint256(tokenSplit) / 10_000);
        assertEq(token.balanceOf(address(lbp.auction())), expectedAuctionAmount);
        assertEq(token.balanceOf(address(lbp)), totalSupply - expectedAuctionAmount);
        assertGe(token.balanceOf(address(lbp)), token.balanceOf(address(lbp.auction())));
    }

    function test_fuzz_onTokenReceived_succeeds() public {
        uint128 totalSupply = 186110499033859115776668960446522303;
        vm.assume(totalSupply > 1);
        setupWithSupply(totalSupply);

        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived();

        // Verify auction is created
        assertNotEq(address(lbp.auction()), address(0));

        // Verify token distribution
        uint256 expectedAuctionAmount = uint128(uint256(totalSupply) * uint256(DEFAULT_TOKEN_SPLIT) / 10_000);
        assertEq(token.balanceOf(address(lbp.auction())), expectedAuctionAmount);
        assertEq(token.balanceOf(address(lbp)), totalSupply - expectedAuctionAmount);
    }

    function test_fuzz_constructor_validation(
        uint24 poolLPFee,
        int24 poolTickSpacing,
        uint16 tokenSplit,
        address positionRecipient
    ) public {
        // Test token split validation
        if (tokenSplit > 5_000) {
            vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.TokenSplitTooHigh.selector, tokenSplit));
        }
        // Test tick spacing validation
        else if (poolTickSpacing < TickMath.MIN_TICK_SPACING || poolTickSpacing > TickMath.MAX_TICK_SPACING) {
            vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidTickSpacing.selector, poolTickSpacing));
        }
        // Test fee validation
        else if (poolLPFee > LPFeeLibrary.MAX_LP_FEE) {
            vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.InvalidFee.selector, poolLPFee));
        }
        // Test position recipient validation
        else if (positionRecipient == address(0) || positionRecipient == address(1) || positionRecipient == address(2))
        {
            vm.expectRevert(
                abi.encodeWithSelector(ILBPStrategyBasic.InvalidPositionRecipient.selector, positionRecipient)
            );
        } else if (uint128(uint256(DEFAULT_TOTAL_SUPPLY) * uint256(tokenSplit) / 10_000) == 0) {
            vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBasic.AuctionSupplyIsZero.selector));
        }

        // Should succeed with valid params
        new LBPStrategyBasicNoValidation(
            address(token),
            DEFAULT_TOTAL_SUPPLY,
            createMigratorParams(address(0), poolLPFee, poolTickSpacing, tokenSplit, positionRecipient),
            auctionParams,
            IPositionManager(POSITION_MANAGER),
            IPoolManager(POOL_MANAGER)
        );
    }
}
