// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IBeneficiaryVault} from "../../src/interfaces/IBeneficiaryVault.sol";
import {IClaimableRecipient} from "../../src/interfaces/IClaimableRecipient.sol";
import {FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {BeneficiaryVault} from "../../src/periphery/BeneficiaryVault.sol";
import {FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {UERC20BeneficiaryVault} from "../../src/periphery/UERC20BeneficiaryVault.sol";
import {CompoundingClaimRecipient} from "../../src/periphery/CompoundingClaimRecipient.sol";
import {VestingClaimRecipient} from "../../src/periphery/VestingClaimRecipient.sol";
import {MockUERC20} from "../mocks/MockUERC20.sol";
import {PositionRecipientTestBase} from "./PositionRecipientTestBase.sol";
import {
    MockPositionManager,
    BaseClaimRecipientHarness
} from "./btt/positionRecipients/definitions/positionRecipients.sol";

/// @title VestingClaimRecipientTest
/// @notice Integration tests for the vesting hot path: a beneficiary vault custodied by the vesting contract,
///         drained by permissionless `claimFrom`, then released to the pinned recipient under the per-block cap.
/// @dev Wired against `MockPositionManager` rather than a fork so the release schedule can be driven by
///      `vm.roll` across many blocks.
contract VestingClaimRecipientTest is Test {
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant FEES_0 = 2 ether;
    uint256 internal constant FEES_1 = 3 ether;
    uint128 internal constant INITIAL_LIQUIDITY = 100 ether;
    uint128 internal constant MAX_PER_BLOCK = 0.5 ether;
    address internal constant NATIVE_FALLBACK = address(0xdead);
    address internal constant TOKEN_FALLBACK = address(0xbeef);

    address internal creator = makeAddr("creator");
    address internal searcher = makeAddr("searcher");
    address internal stranger = makeAddr("stranger");

    MockPositionManager internal manager;
    UERC20BeneficiaryVault internal vault;
    VestingClaimRecipient internal vesting;
    BaseClaimRecipientHarness internal pinned;

    MockUERC20 internal launchToken;
    PoolKey internal poolKey;

    function setUp() public {
        manager = new MockPositionManager();
        launchToken = new MockUERC20("Launch", "LAUNCH", 1_000_000 ether, address(this), creator);
        poolKey = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(launchToken)), 3000, 60, IHooks(address(0)));
        manager.configure(poolKey, TOKEN_ID, FEES_0, FEES_1, INITIAL_LIQUIDITY, 1 ether);

        vault = new UERC20BeneficiaryVault(IPositionManager(address(manager)), NATIVE_FALLBACK, TOKEN_FALLBACK);
        pinned = new BaseClaimRecipientHarness(IPositionManager(address(manager)));
        vesting = new VestingClaimRecipient(
            IPositionManager(address(manager)), MAX_PER_BLOCK, MAX_PER_BLOCK, IClaimableRecipient(address(pinned))
        );
    }

    function test_Integration_WhenCreatorTransfersTheNftIn_VestingBecomesTheOnlyPuller() public {
        _registerTo(creator);
        vm.prank(creator);
        vault.transferFrom(creator, address(vesting), TOKEN_ID);
        _fundVault(FEES_0, FEES_1);

        assertEq(vault.ownerOf(TOKEN_ID), address(vesting));

        // the creator can no longer drain the vault directly
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotBeneficiary.selector, TOKEN_ID, creator));
        vault.claim(TOKEN_ID, 0, 0);

        // nor can anyone else
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotBeneficiary.selector, TOKEN_ID, stranger));
        vault.claim(TOKEN_ID, 0, 0);

        // only the vesting contract, and only through the permissionless `claimFrom`
        vm.prank(searcher);
        vesting.claimFrom(vault, TOKEN_ID, uint128(FEES_0), uint128(FEES_1));

        (uint256 amounts0, uint256 amounts1) = vesting.amounts(TOKEN_ID);
        assertEq(amounts0, FEES_0);
        assertEq(amounts1, FEES_1);
        (uint256 vaultAmounts0, uint256 vaultAmounts1) = vault.amounts(TOKEN_ID);
        assertEq(vaultAmounts0, 0);
        assertEq(vaultAmounts1, 0);
    }

    function test_Integration_WhenClaimedEveryBlock_DripsToTheRecipientUnderTheCap() public {
        _onboardAndPull();

        for (uint256 i = 1; i <= 6; i++) {
            vm.prank(searcher);
            vesting.claim(TOKEN_ID, 0, 0);

            assertEq(
                Currency.wrap(address(0)).balanceOf(address(pinned)),
                FixedPointMathLib.min(uint256(MAX_PER_BLOCK) * i, FEES_0),
                "currency0 drip"
            );
            assertEq(
                launchToken.balanceOf(address(pinned)),
                FixedPointMathLib.min(uint256(MAX_PER_BLOCK) * i, FEES_1),
                "currency1 drip"
            );
            vm.roll(block.number + 1);
        }

        // fully drained, and every unit was registered on the recipient
        (uint256 amounts0, uint256 amounts1) = vesting.amounts(TOKEN_ID);
        assertEq(amounts0, 0);
        assertEq(amounts1, 0);
        (uint256 pinned0, uint256 pinned1) = pinned.amounts(TOKEN_ID);
        assertEq(pinned0, FEES_0);
        assertEq(pinned1, FEES_1);
    }

    function test_Integration_WhenDrivenByAnyCaller_FundsAlwaysReachThePinnedRecipient(address caller) public {
        vm.assume(caller != address(0) && caller != address(vesting) && caller != address(pinned));
        vm.assume(caller.code.length == 0);
        _onboardAndPull();
        uint256 callerBalanceBefore = caller.balance;

        vm.prank(caller);
        vesting.claim(TOKEN_ID, 0, 0);

        assertEq(Currency.wrap(address(0)).balanceOf(address(pinned)), MAX_PER_BLOCK);
        assertEq(launchToken.balanceOf(address(pinned)), MAX_PER_BLOCK);
        assertEq(caller.balance, callerBalanceBefore, "the caller is never paid by this hop");
        assertEq(launchToken.balanceOf(caller), 0);
    }

    function test_Integration_WhenRecipientIsCompounding_ReleasedAmountsBecomeCompoundable() public {
        CompoundingClaimRecipient compounding = new CompoundingClaimRecipient(IPositionManager(address(manager)), 1);
        vesting = new VestingClaimRecipient(
            IPositionManager(address(manager)), MAX_PER_BLOCK, MAX_PER_BLOCK, IClaimableRecipient(address(compounding))
        );
        _onboardAndPull();

        vm.prank(searcher);
        vesting.claim(TOKEN_ID, 0, 0);
        // the gap does not accrue: the second claim still releases at most one block's maximum
        vm.roll(block.number + 3);
        vm.prank(searcher);
        vesting.claim(TOKEN_ID, 0, 0);

        uint256 released = uint256(MAX_PER_BLOCK) * 2;
        assertEq(Currency.wrap(address(0)).balanceOf(address(compounding)), released);
        assertEq(launchToken.balanceOf(address(compounding)), released);
        // the compounding recipient now holds them as claimable, ready for an executor to deposit
        (uint256 amounts0, uint256 amounts1) = compounding.amounts(TOKEN_ID);
        assertEq(amounts0, released);
        assertEq(amounts1, released);
    }

    function test_Integration_WhenTwoVaultsFeedOneTokenId_AmountsAggregateBeforeVesting() public {
        BeneficiaryVault second =
            new BeneficiaryVault(IPositionManager(address(manager)), NATIVE_FALLBACK, TOKEN_FALLBACK);
        _registerTo(address(vesting));
        manager.setPositionOwner(creator);
        vm.prank(creator);
        second.registerBeneficiary(TOKEN_ID, address(vesting));

        _fundVault(FEES_0, FEES_1);
        vm.deal(address(second), FEES_0);
        launchToken.transfer(address(second), FEES_1);
        second.onAmountsReceived(TOKEN_ID, FEES_0, FEES_1);

        vm.startPrank(searcher);
        vesting.claimFrom(vault, TOKEN_ID, uint128(FEES_0), uint128(FEES_1));
        vesting.claimFrom(second, TOKEN_ID, uint128(FEES_0), uint128(FEES_1));
        vm.stopPrank();

        (uint256 amounts0, uint256 amounts1) = vesting.amounts(TOKEN_ID);
        assertEq(amounts0, FEES_0 * 2, "both sources attribute to the canonical tokenId");
        assertEq(amounts1, FEES_1 * 2);
        assertEq(vesting.totalAmounts(poolKey.currency0), FEES_0 * 2);
        assertEq(vesting.totalAmounts(poolKey.currency1), FEES_1 * 2);
    }

    function test_Integration_WhenRegisteredStraightToVesting_NoTransferIsNeeded() public {
        _registerTo(address(vesting));
        _fundVault(FEES_0, FEES_1);

        assertEq(vault.ownerOf(TOKEN_ID), address(vesting));

        vm.prank(searcher);
        vesting.claimFrom(vault, TOKEN_ID, uint128(FEES_0), uint128(FEES_1));

        (uint256 amounts0,) = vesting.amounts(TOKEN_ID);
        assertEq(amounts0, FEES_0);
    }

    function test_Integration_WhenSourceHasNothingToPay_ClaimFromIsANoop() public {
        _registerTo(address(vesting));

        vm.prank(searcher);
        vesting.claimFrom(vault, TOKEN_ID, 0, 0);

        (uint256 amounts0, uint256 amounts1) = vesting.amounts(TOKEN_ID);
        assertEq(amounts0, 0);
        assertEq(amounts1, 0);
        assertEq(vesting.lastClaimed(TOKEN_ID), 0, "claimFrom does not process a release");
    }

    /// @notice Registers the beneficiary NFT for TOKEN_ID to `beneficiary`, authorised by position custody
    function _registerTo(address beneficiary) internal {
        manager.setPositionOwner(creator);
        vm.prank(creator);
        vault.registerBeneficiary(TOKEN_ID, beneficiary);
    }

    /// @notice Transfers fees to the vault and attributes them to TOKEN_ID
    function _fundVault(uint256 amount0, uint256 amount1) internal {
        vm.deal(address(vault), address(vault).balance + amount0);
        launchToken.transfer(address(vault), amount1);
        vault.onAmountsReceived(TOKEN_ID, amount0, amount1);
    }

    /// @notice Full onboarding: NFT into the vesting contract, fees funded, then pulled out of the vault
    function _onboardAndPull() internal {
        _registerTo(creator);
        vm.prank(creator);
        vault.transferFrom(creator, address(vesting), TOKEN_ID);
        _fundVault(FEES_0, FEES_1);

        vm.prank(searcher);
        vesting.claimFrom(vault, TOKEN_ID, uint128(FEES_0), uint128(FEES_1));
    }
}

/// @title VestingClaimRecipientForkTest
/// @notice The same hot path against the canonical v4 PositionManager, so pool key resolution and custody
///         checks run against real position state rather than a mock.
contract VestingClaimRecipientForkTest is PositionRecipientTestBase {
    uint128 internal constant NATIVE_MAX_PER_BLOCK = 1e11;
    uint128 internal constant USDC_MAX_PER_BLOCK = 1e6;
    uint256 internal constant USDC_FEES = 10e6;

    address internal nativeFallback = makeAddr("nativeFallback");
    address internal tokenFallback = makeAddr("tokenFallback");
    address internal searcher = makeAddr("searcher");

    VestingClaimRecipient internal vesting;
    BaseClaimRecipientHarness internal pinned;

    function setUp() public override {
        super.setUp();
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        pinned = new BaseClaimRecipientHarness(IPositionManager(POSITION_MANAGER));
        vesting = new VestingClaimRecipient(
            IPositionManager(POSITION_MANAGER),
            NATIVE_MAX_PER_BLOCK,
            USDC_MAX_PER_BLOCK,
            IClaimableRecipient(address(pinned))
        );
    }

    function test_Fork_CanReceiveETH() public {
        uint256 balanceBefore = address(vesting).balance;
        vm.deal(address(this), 1 ether);
        (bool success,) = address(vesting).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(vesting).balance, balanceBefore + 1 ether);
    }

    function test_Fork_Claim_WhenPositionDoesNotExist_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimableRecipient.InvalidPosition.selector, type(uint256).max));
        vesting.claim(type(uint256).max, 0, 0);
    }

    function test_Fork_Claim_ReleasesPerBlockMaxAgainstRealPosition(uint256 gapBlocks) public {
        gapBlocks = bound(gapBlocks, 1, 1000);
        _attribute(FORK_CURRENCY0_FEES_AMOUNT, USDC_FEES);
        // the harness address may already hold mainnet balance at this fork, so assert deltas
        uint256 nativeBefore = address(pinned).balance;
        uint256 usdcBefore = Currency.wrap(USDC).balanceOf(address(pinned));

        vesting.claim(FORK_TOKEN_ID, 0, 0);
        assertEq(vesting.lastClaimed(FORK_TOKEN_ID), block.number);
        assertEq(address(pinned).balance - nativeBefore, NATIVE_MAX_PER_BLOCK, "first claim releases one block's max");

        // the gap does not accrue: the next claim releases at most one more block's maximum
        vm.roll(block.number + gapBlocks);
        vm.prank(searcher);
        vesting.claim(FORK_TOKEN_ID, 0, 0);

        uint256 expectedNative = uint256(NATIVE_MAX_PER_BLOCK) * 2;
        uint256 expectedUsdc = uint256(USDC_MAX_PER_BLOCK) * 2;
        assertEq(address(pinned).balance - nativeBefore, expectedNative, "native release is capped");
        assertEq(Currency.wrap(USDC).balanceOf(address(pinned)) - usdcBefore, expectedUsdc, "USDC release is capped");
        (uint256 amounts0, uint256 amounts1) = vesting.amounts(FORK_TOKEN_ID);
        assertEq(amounts0, FORK_CURRENCY0_FEES_AMOUNT - expectedNative);
        assertEq(amounts1, USDC_FEES - expectedUsdc);
    }

    function test_Fork_ClaimFrom_PullsFromRealBeneficiaryVault() public {
        BeneficiaryVault vault = new BeneficiaryVault(IPositionManager(POSITION_MANAGER), nativeFallback, tokenFallback);
        _yoinkPosition(FORK_TOKEN_ID, address(this));
        vault.registerBeneficiary(FORK_TOKEN_ID, address(vesting));

        vm.deal(address(vault), FORK_CURRENCY0_FEES_AMOUNT);
        _dealUSDCFromPoolManager(address(vault), USDC_FEES);
        vault.onAmountsReceived(FORK_TOKEN_ID, FORK_CURRENCY0_FEES_AMOUNT, USDC_FEES);

        // the vault only pays its beneficiary NFT holder, which is the vesting contract
        vm.prank(searcher);
        vm.expectRevert(abi.encodeWithSelector(IBeneficiaryVault.NotBeneficiary.selector, FORK_TOKEN_ID, searcher));
        vault.claim(FORK_TOKEN_ID, 0, 0);

        vm.prank(searcher);
        vesting.claimFrom(vault, FORK_TOKEN_ID, uint128(FORK_CURRENCY0_FEES_AMOUNT), uint128(USDC_FEES));

        (uint256 amounts0, uint256 amounts1) = vesting.amounts(FORK_TOKEN_ID);
        assertEq(amounts0, FORK_CURRENCY0_FEES_AMOUNT);
        assertEq(amounts1, USDC_FEES);
        (uint256 vaultAmounts0, uint256 vaultAmounts1) = vault.amounts(FORK_TOKEN_ID);
        assertEq(vaultAmounts0, 0);
        assertEq(vaultAmounts1, 0);
    }

    /// @notice The full production path in one test: real LP fees collected by `FeeSplitter`, pushed to a
    ///         `BeneficiaryVault`, drained by the `VestingClaimRecipient` custodying its NFT, then released
    ///         to the pinned final recipient. Each leg asserts the hand-off the separate suites cannot.
    function test_Fork_E2E_FeeSplitterToVaultToVestingToRecipient() public {
        BeneficiaryVault vault = new BeneficiaryVault(IPositionManager(POSITION_MANAGER), nativeFallback, tokenFallback);
        FeeSplit[] memory splits = new FeeSplit[](1);
        splits[0] = FeeSplit({recipient: address(vault), nativeBps: 10_000, tokenBps: 10_000, useCallback: true});
        FeeSplitter feeSplitter = new FeeSplitter(IPositionManager(POSITION_MANAGER), splits);

        // registration is authorized by position custody, so it happens before the position moves away
        _yoinkPosition(FORK_TOKEN_ID, address(this));
        vault.registerBeneficiary(FORK_TOKEN_ID, address(vesting));
        IERC721(POSITION_MANAGER).transferFrom(address(this), address(feeSplitter), FORK_TOKEN_ID);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = FORK_TOKEN_ID;
        feeSplitter.collectFees(tokenIds);

        // leg 1: real collected fees are attributed in the vault against the canonical token ID
        (uint256 vaultNative, uint256 vaultUsdc) = vault.amounts(FORK_TOKEN_ID);
        assertEq(vaultNative, FORK_CURRENCY0_FEES_AMOUNT, "collected native fees reached the vault");
        assertGt(vaultUsdc, 0, "collected USDC fees reached the vault");

        // leg 2: the vault pays only its beneficiary NFT holder, but anyone may trigger the pull
        vm.prank(searcher);
        vesting.claimFrom(vault, FORK_TOKEN_ID, uint128(vaultNative), uint128(vaultUsdc));

        (uint256 vestingNative, uint256 vestingUsdc) = vesting.amounts(FORK_TOKEN_ID);
        assertEq(vestingNative, vaultNative, "the whole vault balance moved to vesting");
        assertEq(vestingUsdc, vaultUsdc);
        (vaultNative, vaultUsdc) = vault.amounts(FORK_TOKEN_ID);
        assertEq(vaultNative, 0, "the vault retains nothing");
        assertEq(vaultUsdc, 0);

        // leg 3: the release to the final recipient is capped per block and registered there
        uint256 expectedNative = FixedPointMathLib.min(vestingNative, NATIVE_MAX_PER_BLOCK);
        uint256 expectedUsdc = FixedPointMathLib.min(vestingUsdc, USDC_MAX_PER_BLOCK);
        uint256 nativeBefore = address(pinned).balance;
        uint256 usdcBefore = Currency.wrap(USDC).balanceOf(address(pinned));

        vm.prank(searcher);
        vesting.claim(FORK_TOKEN_ID, 0, 0);

        assertEq(address(pinned).balance - nativeBefore, expectedNative, "final recipient received the native cap");
        assertEq(
            Currency.wrap(USDC).balanceOf(address(pinned)) - usdcBefore,
            expectedUsdc,
            "final recipient received the USDC cap"
        );
        (uint256 pinnedNative, uint256 pinnedUsdc) = pinned.amounts(FORK_TOKEN_ID);
        assertEq(pinnedNative, expectedNative, "the release was registered on the final recipient");
        assertEq(pinnedUsdc, expectedUsdc);
    }

    function _attribute(uint256 nativeAmount, uint256 usdcAmount) internal {
        vm.deal(address(vesting), address(vesting).balance + nativeAmount);
        _dealUSDCFromPoolManager(address(vesting), usdcAmount);
        vesting.onAmountsReceived(FORK_TOKEN_ID, nativeAmount, usdcAmount);
    }
}
