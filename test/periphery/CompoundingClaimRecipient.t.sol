// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IClaimableRecipient} from "../../src/interfaces/IClaimableRecipient.sol";
import {IBeneficiaryVault} from "../../src/interfaces/IBeneficiaryVault.sol";
import {CompoundingClaimRecipient} from "../../src/periphery/CompoundingClaimRecipient.sol";
import {BeneficiaryVault} from "../../src/periphery/BeneficiaryVault.sol";
import {FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {IFeeSplitter, FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {MockClaimExecutor} from "./MockClaimExecutor.sol";
import {MockCompoundingClaimExecutor} from "./MockCompoundingClaimExecutor.sol";
import {PositionRecipientTestBase} from "./PositionRecipientTestBase.sol";

contract CompoundingClaimRecipientTest is PositionRecipientTestBase {
    address internal constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    CompoundingClaimRecipient internal positionRecipient;
    MockCompoundingClaimExecutor internal executor;
    BeneficiaryVault internal beneficiaryVault;
    address internal nativeFallback = makeAddr("nativeFallback");
    address internal tokenFallback = makeAddr("tokenFallback");

    function setUp() public override {
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        executor = new MockCompoundingClaimExecutor(IPositionManager(POSITION_MANAGER), IWETH9(WETH9));
    }

    function test_Constructor_WhenMinimumLiquidityIncreaseIsZero_Reverts() public {
        vm.expectRevert(CompoundingClaimRecipient.MinLiquidityIncreaseIsZero.selector);
        new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), 0);
    }

    function test_Constructor_WhenParametersAreValid_SetsConfiguration(uint128 minLiquidityIncrease) public {
        minLiquidityIncrease = uint128(bound(minLiquidityIncrease, 1, type(uint128).max));
        positionRecipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), minLiquidityIncrease);

        assertEq(positionRecipient.minLiquidityIncrease(), minLiquidityIncrease);
        assertEq(address(positionRecipient.positionManager()), POSITION_MANAGER);
    }

    function test_CanReceiveETH() public {
        positionRecipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        uint256 balanceBefore = address(positionRecipient).balance;
        vm.deal(address(this), 1 ether);
        (bool success,) = address(positionRecipient).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(positionRecipient).balance, balanceBefore + 1 ether);
    }

    function test_Claim_WhenPositionDoesNotExist_Reverts() public {
        positionRecipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), 1);

        vm.expectRevert(abi.encodeWithSelector(IClaimableRecipient.InvalidPosition.selector, type(uint256).max));
        executor.execute(positionRecipient, type(uint256).max, 0, 0);
    }

    function test_OnAmountsReceived_WhenPositionIsNotOwned_RecordsAmounts() public {
        positionRecipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        vm.deal(address(positionRecipient), FORK_CURRENCY0_FEES_AMOUNT);

        positionRecipient.onAmountsReceived(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0);

        (uint256 currency0Amount, uint256 currency1Amount) = positionRecipient.amounts(FORK_TOKEN_ID);
        assertEq(currency0Amount, FORK_CURRENCY0_FEES_AMOUNT);
        assertEq(currency1Amount, 0);
    }

    function test_Claim_WhenLiquidityIncreaseIsInsufficient_Reverts() public {
        positionRecipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), type(uint128).max);
        MockClaimExecutor noopExecutor = new MockClaimExecutor();
        _yoinkPosition(FORK_TOKEN_ID, address(positionRecipient));
        uint128 liquidityBefore = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                CompoundingClaimRecipient.NotEnoughLiquidityAdded.selector,
                uint256(liquidityBefore) + type(uint128).max,
                liquidityBefore
            )
        );
        noopExecutor.execute(positionRecipient, FORK_TOKEN_ID, 0, 0);
    }

    function test_Claim_WhenExecutorDepositsProceeds_IncreasesLiquidity() public {
        positionRecipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        FeeSplitter splitter = _callbackSplitter(address(positionRecipient));
        uint256 recipientCurrency0Before = Currency.wrap(NATIVE).balanceOf(address(positionRecipient));
        uint256 recipientCurrency1Before = Currency.wrap(USDC).balanceOf(address(positionRecipient));
        _yoinkPosition(FORK_TOKEN_ID, address(splitter));
        splitter.collectFees(_single(FORK_TOKEN_ID));
        executor.setFeeSplitter(IFeeSplitter(address(splitter)), 1);
        uint128 liquidityBefore = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);

        executor.execute(positionRecipient, FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, 0);

        uint128 liquidityAfter = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);
        assertGt(liquidityAfter, liquidityBefore);
        assertEq(executor.lastTokenId(), FORK_TOKEN_ID);
        assertEq(executor.lastCurrency0Received(), FORK_CURRENCY0_FEES_AMOUNT);
        assertGt(executor.lastCurrency1Received(), 0);
        assertEq(Currency.wrap(NATIVE).balanceOf(address(positionRecipient)), recipientCurrency0Before);
        assertEq(Currency.wrap(USDC).balanceOf(address(positionRecipient)), recipientCurrency1Before);
    }

    function test_ClaimFrom_WhenRecipientOwnsNft_AttributesExternalShare() public {
        positionRecipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        beneficiaryVault = new BeneficiaryVault(IPositionManager(POSITION_MANAGER), nativeFallback, tokenFallback);
        FeeSplitter splitter = _productionSplitter(address(beneficiaryVault), address(positionRecipient));

        _yoinkPosition(FORK_TOKEN_ID, address(this));
        beneficiaryVault.registerBeneficiary(FORK_TOKEN_ID, address(positionRecipient));
        IERC721(POSITION_MANAGER).transferFrom(address(this), address(splitter), FORK_TOKEN_ID);
        splitter.collectFees(_single(FORK_TOKEN_ID));

        (uint256 vaultNative,) = beneficiaryVault.amounts(FORK_TOKEN_ID);
        assertGt(vaultNative, 0);

        positionRecipient.claimFrom(beneficiaryVault, FORK_TOKEN_ID, 0, 0);

        (uint256 vaultNativeAfter,) = beneficiaryVault.amounts(FORK_TOKEN_ID);
        (uint256 recipientNative,) = positionRecipient.amounts(FORK_TOKEN_ID);
        assertEq(vaultNativeAfter, 0);
        assertGe(recipientNative, vaultNative);
    }

    function test_ClaimFrom_WhenRecipientDoesNotOwnNft_Reverts() public {
        positionRecipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        beneficiaryVault = new BeneficiaryVault(IPositionManager(POSITION_MANAGER), nativeFallback, tokenFallback);
        FeeSplitter splitter = _productionSplitter(address(beneficiaryVault), address(positionRecipient));
        address otherBeneficiary = makeAddr("otherBeneficiary");

        _yoinkPosition(FORK_TOKEN_ID, address(this));
        beneficiaryVault.registerBeneficiary(FORK_TOKEN_ID, otherBeneficiary);
        IERC721(POSITION_MANAGER).transferFrom(address(this), address(splitter), FORK_TOKEN_ID);
        splitter.collectFees(_single(FORK_TOKEN_ID));

        vm.expectRevert(
            abi.encodeWithSelector(
                IBeneficiaryVault.NotApprovedOrOwner.selector, FORK_TOKEN_ID, address(positionRecipient)
            )
        );
        positionRecipient.claimFrom(beneficiaryVault, FORK_TOKEN_ID, 0, 0);
    }

    function test_ClaimFrom_WhenExternalShareIsPulledFirst_ExecutorCompoundsAll() public {
        positionRecipient = new CompoundingClaimRecipient(IPositionManager(POSITION_MANAGER), 1);
        beneficiaryVault = new BeneficiaryVault(IPositionManager(POSITION_MANAGER), nativeFallback, tokenFallback);
        FeeSplitter splitter = _productionSplitter(address(beneficiaryVault), address(positionRecipient));

        _yoinkPosition(FORK_TOKEN_ID, address(this));
        beneficiaryVault.registerBeneficiary(FORK_TOKEN_ID, address(positionRecipient));
        IERC721(POSITION_MANAGER).transferFrom(address(this), address(splitter), FORK_TOKEN_ID);
        splitter.collectFees(_single(FORK_TOKEN_ID));

        (uint256 vaultNativeBefore,) = beneficiaryVault.amounts(FORK_TOKEN_ID);
        (uint256 recipientNativeBefore, uint256 recipientTokenBefore) = positionRecipient.amounts(FORK_TOKEN_ID);
        assertGt(vaultNativeBefore, 0);
        assertGt(recipientNativeBefore, 0);
        assertGt(recipientTokenBefore, 0);

        positionRecipient.claimFrom(beneficiaryVault, FORK_TOKEN_ID, 0, 0);

        uint128 liquidityBefore = IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID);
        executor.setFeeSplitter(IFeeSplitter(address(splitter)), 1);
        executor.execute(positionRecipient, FORK_TOKEN_ID, recipientNativeBefore + vaultNativeBefore, 0);

        assertGt(IPositionManager(POSITION_MANAGER).getPositionLiquidity(FORK_TOKEN_ID), liquidityBefore);
        assertEq(executor.lastCurrency0Received(), recipientNativeBefore + vaultNativeBefore);
        assertEq(executor.lastCurrency1Received(), recipientTokenBefore);
        (uint256 recipientNativeAfter, uint256 recipientTokenAfter) = positionRecipient.amounts(FORK_TOKEN_ID);
        assertEq(recipientNativeAfter, 0);
        assertEq(recipientTokenAfter, 0);
    }

    function _productionSplitter(address vault, address recipient) internal returns (FeeSplitter splitter) {
        FeeSplit[] memory splits = new FeeSplit[](2);
        splits[0] = FeeSplit({recipient: vault, nativeBps: 4_000, tokenBps: 0, useCallback: true});
        splits[1] = FeeSplit({recipient: recipient, nativeBps: 6_000, tokenBps: 10_000, useCallback: true});
        splitter = new FeeSplitter(IPositionManager(POSITION_MANAGER), splits);
    }

    function _callbackSplitter(address recipient) internal returns (FeeSplitter splitter) {
        FeeSplit[] memory splits = new FeeSplit[](1);
        splits[0] = FeeSplit({recipient: recipient, nativeBps: 10_000, tokenBps: 10_000, useCallback: true});
        splitter = new FeeSplitter(IPositionManager(POSITION_MANAGER), splits);
    }

    function _single(uint256 tokenId) internal pure returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
    }
}
