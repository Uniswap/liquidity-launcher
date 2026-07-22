// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    DirectLaunchTestBase,
    MockDirectShortTransferToken,
    MockDirectSixDecimalToken
} from "../../base/DirectLaunchTestBase.sol";
import {DirectLaunchStrategy, DirectLaunchConfig} from "../../../../../src/strategies/DirectLaunchStrategy.sol";
import {IStrategy} from "../../../../../src/interfaces/IStrategy.sol";
import {IFeeSplitter} from "../../../../../src/interfaces/IFeeSplitter.sol";
import {MockERC20} from "../../../../mocks/MockERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @title InitializeDistributionTest
/// @notice BTT tests for DirectLaunchStrategy.initializeDistribution
///
/// initializeDistribution
/// ├── when the caller is not the launcher
/// │   └── it reverts with OnlyLauncher
/// ├── when configData is empty
/// │   └── it reverts with InvalidConfigData
/// ├── when configData is malformed
/// │   └── it reverts in the decode
/// ├── when the fee beneficiary is the zero address or the launcher
/// │   └── it reverts with InvalidFeeBeneficiary
/// ├── when the configuration is valid
/// │   └── it registers the beneficiary with the fee splitter
/// ├── when either supply is not the fixed supply
/// │   └── it reverts with InvalidSupply
/// ├── when the token does not use 18 decimals
/// │   └── it reverts with InvalidTokenDecimals
/// ├── when the received token amount is not exact
/// │   └── it reverts with TokenAmountMismatch
/// ├── when the pool is already initialized
/// │   └── it reverts with PoolAlreadyInitialized
/// └── when the launch is valid
///     ├── it preserves preexisting balances
///     ├── it opens the pool at the initial price
///     ├── it mints one single-sided position holding the full supply
///     ├── it custodies the position in the fee splitter
///     ├── it retains no tokens and burns only dust
///     └── it emits the launch events
contract InitializeDistributionTest is DirectLaunchTestBase {
    using StateLibrary for IPoolManager;

    function _key(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: strategy.LP_FEE(),
            tickSpacing: strategy.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
    }

    function test_WhenCallerIsNotLauncher() public {
        vm.expectRevert(DirectLaunchStrategy.OnlyLauncher.selector);
        vm.prank(makeAddr("unauthorized"));
        strategy.initializeDistribution(address(1), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenConfigDataIsEmpty() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectRevert(DirectLaunchStrategy.InvalidConfigData.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, bytes(""), bytes32(0));
    }

    function test_WhenConfigDataIsMalformed() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectRevert();
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, hex"01", bytes32(0));
    }

    function test_fuzz_WhenFeeBeneficiaryIsInvalid(bool useLauncher) public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        token.approve(address(strategy), TOTAL_SUPPLY);
        address invalid = useLauncher ? launcher : address(0);
        vm.expectRevert(abi.encodeWithSelector(DirectLaunchStrategy.InvalidFeeBeneficiary.selector, invalid));
        strategy.initializeDistribution(
            address(token), TOTAL_SUPPLY, abi.encode(DirectLaunchConfig({feeBeneficiary: invalid})), bytes32(0)
        );
    }

    function test_WhenConfigurationIsValid_registersBeneficiaryWithFeeSplitter() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectEmit(true, true, true, true, address(feeSplitter));
        emit IFeeSplitter.FeeBeneficiarySet(tokenId, launchFeeBeneficiary);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));

        // The configured beneficiary is registered and the splitter holds the position.
        assertEq(feeSplitter.feeBeneficiary(tokenId), launchFeeBeneficiary);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(feeSplitter));
    }

    function test_WhenDistributionAmountIsNotFixedSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        vm.expectRevert(DirectLaunchStrategy.InvalidSupply.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY - 1, _defaultConfig(), bytes32(0));
    }

    function test_WhenTokenSupplyIsNotFixedSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY - 1);
        vm.expectRevert(DirectLaunchStrategy.InvalidSupply.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenTokenDoesNotUse18Decimals() public {
        MockDirectSixDecimalToken token = new MockDirectSixDecimalToken(TOTAL_SUPPLY, address(this));
        vm.expectRevert(DirectLaunchStrategy.InvalidTokenDecimals.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenReceivedTokenAmountIsNotExact() public {
        MockDirectShortTransferToken token = new MockDirectShortTransferToken(TOTAL_SUPPLY, address(this));
        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(DirectLaunchStrategy.TokenAmountMismatch.selector, TOTAL_SUPPLY - 1, TOTAL_SUPPLY)
        );
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenPoolIsAlreadyInitialized() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        // Anyone can initialize the hookless pool key ahead of the launch; the launch must not
        // silently adopt the attacker's price.
        poolManager.initialize(_key(address(token)), TickMath.getSqrtPriceAtTick(0));

        token.approve(address(strategy), TOTAL_SUPPLY);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    function test_WhenLaunchIsValid_preservesPreexistingBalance() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        // Strand a preexisting balance on the strategy (without changing total supply); the launch's
        // dust sweep must only burn what it added, leaving the preexisting balance intact.
        deal(address(token), address(strategy), 1 ether, false);
        _initialize(token, TOTAL_SUPPLY, _defaultConfig());
        assertEq(token.balanceOf(address(strategy)), 1 ether);
    }

    function test_WhenLaunchIsValid_opensPoolAtInitialPrice() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        _initialize(token, TOTAL_SUPPLY, _defaultConfig());

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(_key(address(token)).toId());
        assertEq(sqrtPriceX96, strategy.initialSqrtPriceX96());
        assertEq(tick, INITIAL_TICK);
    }

    function test_WhenLaunchIsValid_mintsSingleSidedPositionWithFullSupply() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();
        address recipient = address(feeSplitter);

        _initialize(token, TOTAL_SUPPLY, _defaultConfig());

        // One position, spanning the token side of the price, holding the precomputed liquidity.
        assertEq(POSITION_MANAGER.nextTokenId(), tokenId + 1);
        (, PositionInfo info) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        assertEq(info.tickLower(), TickMath.minUsableTick(strategy.TICK_SPACING()));
        assertEq(info.tickUpper(), INITIAL_TICK);
        assertEq(POSITION_MANAGER.getPositionLiquidity(tokenId), strategy.positionLiquidity());
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), recipient);
    }

    function test_WhenLaunchIsValid_custodiesPositionInFeeSplitter() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        _initialize(token, TOTAL_SUPPLY, _defaultConfig());

        // The singleton splitter holds the position permanently; it has no exit path for it.
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(tokenId), address(feeSplitter));
        assertEq(address(feeSplitter.positionManager()), address(POSITION_MANAGER));
    }

    function test_WhenLaunchIsValid_retainsNoTokensAndBurnsOnlyDust() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        _initialize(token, TOTAL_SUPPLY, _defaultConfig());

        uint256 burned = token.balanceOf(address(0xdead));
        // Everything not in the pool is burned rounding dust: less than one token out of a billion.
        assertEq(token.balanceOf(address(poolManager)) + burned, TOTAL_SUPPLY);
        assertLt(burned, 1 ether);
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(positionManager)), 0);
    }

    function test_WhenLaunchIsValid_emitsLaunchEvents() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        PoolKey memory key = _key(address(token));
        address recipient = address(feeSplitter);
        token.approve(address(strategy), TOTAL_SUPPLY);

        vm.expectEmit(true, true, false, true, address(strategy));
        emit IStrategy.DistributionInitialized(address(strategy), address(token), TOTAL_SUPPLY);
        vm.expectEmit(true, true, true, true, address(strategy));
        emit DirectLaunchStrategy.TokenLaunched(key.toId(), address(token), recipient, key);
        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_WhenLaunchIsValid_gas() public {
        MockERC20 token = _deployToken(TOTAL_SUPPLY);
        token.approve(address(strategy), TOTAL_SUPPLY);

        strategy.initializeDistribution(address(token), TOTAL_SUPPLY, _defaultConfig(), bytes32(0));
        vm.snapshotGasLastCall("DirectLaunchStrategy initializeDistribution");
    }
}
