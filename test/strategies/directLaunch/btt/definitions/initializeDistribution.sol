// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DirectLaunchTestBase} from "../../base/DirectLaunchTestBase.sol";
import {IDirectLaunchStrategy} from "../../../../../src/interfaces/IDirectLaunchStrategy.sol";
import {IStrategy} from "../../../../../src/interfaces/IStrategy.sol";
import {DirectLaunchParameters} from "../../../../../src/libraries/DirectLaunchParams.sol";
import {MigratorParams} from "../../../../../src/libraries/MigratorParams.sol";
import {PositionPlanner} from "../../../../../src/libraries/PositionPlanner.sol";
import {LaunchConfig} from "../../../../../src/interfaces/ILaunchHook.sol";
import {IInitializerHook} from "../../../../../src/interfaces/IInitializerHook.sol";
import {PositionDefinition} from "../../../../../src/types/PositionPlannerTypes.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract MockInitializerHook {
    address public immutable authorized;

    constructor(address _authorized) {
        authorized = _authorized;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IInitializerHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @title InitializeDistributionTest
/// @notice BTT tests for DirectLaunchStrategy.initializeDistribution
///
/// initializeDistribution
/// ├── when token is the zero address
/// │   └── it reverts with ZeroAddressToken
/// ├── when totalSupply is zero
/// │   └── it reverts with InvalidAmount
/// ├── when totalSupply exceeds int128 max
/// │   └── it reverts with InvalidAmount
/// ├── when token and currency are the same
/// │   └── it reverts with InvalidTokenCurrencyPair
/// ├── when tickSpacing is out of bounds
/// │   └── it reverts with InvalidTickSpacing
/// ├── when fee > MAX_LP_FEE and not the dynamic fee flag
/// │   └── it reverts with InvalidFee
/// ├── when fee is the dynamic fee flag without a hook
/// │   └── it reverts with InvalidDynamicFeeHook
/// ├── when recipient is the zero address
/// │   └── it reverts with InvalidRecipient
/// ├── when positionRecipient is reserved or zero
/// │   └── it reverts with InvalidPositionRecipient
/// ├── when position definition weights do not sum to 1e7
/// │   └── it reverts with IncompleteAllocation
/// ├── when position definitions are empty
/// │   └── it reverts with IncompleteAllocation
/// ├── when a position is not on the token side of the price
/// │   └── it reverts with PositionNotSingleSided
/// ├── when the hook's authorized address is not the strategy
/// │   └── it reverts with InvalidHook
/// ├── when the pool is already initialized
/// │   └── it reverts with InvalidHook
/// ├── when the hook supports ILaunchHook
/// │   ├── when launchConfig is empty
/// │   │   └── it reverts with MissingLaunchConfig
/// │   └── when launchConfig is valid
/// │       └── it registers the launch config on the hook
/// ├── when the hook does not support ILaunchHook
/// │   └── when launchConfig is non-empty
/// │       └── it reverts with UnexpectedLaunchConfig
/// └── when params are valid
///     ├── it initializes the pool at the configured price
///     ├── it mints one position per definition to the resolved recipients
///     ├── it consumes the caller's allowance fully
///     ├── it sweeps unplaced tokens to the recipient
///     └── it emits TokenLaunched
contract InitializeDistributionTest is DirectLaunchTestBase {
    using StateLibrary for IPoolManager;

    function test_WhenTokenIsZeroAddress() public {
        vm.expectRevert(IDirectLaunchStrategy.ZeroAddressToken.selector);
        strategy.initializeDistribution(address(0), DEFAULT_SUPPLY, hex"", bytes32(0));
    }

    function test_WhenTotalSupplyIsZero() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IStrategy.InvalidAmount.selector, 0, uint128(type(int128).max)));
        strategy.initializeDistribution(address(token), 0, hex"", bytes32(0));
    }

    function test_fuzz_WhenTotalSupplyExceedsInt128Max(uint256 totalSupply) public {
        totalSupply = bound(totalSupply, uint256(uint128(type(int128).max)) + 1, type(uint256).max);
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);

        vm.expectRevert(
            abi.encodeWithSelector(IStrategy.InvalidAmount.selector, totalSupply, uint128(type(int128).max))
        );
        strategy.initializeDistribution(address(token), totalSupply, hex"", bytes32(0));
    }

    function test_WhenTokenAndCurrencyAreTheSame() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params = _params(address(token), address(0), BASE_FEE, hex"", false);

        vm.expectRevert(
            abi.encodeWithSelector(IDirectLaunchStrategy.InvalidTokenCurrencyPair.selector, address(token))
        );
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_fuzz_WhenTickSpacingIsOutOfBounds(int24 tickSpacing) public {
        vm.assume(tickSpacing > TickMath.MAX_TICK_SPACING || tickSpacing < TickMath.MIN_TICK_SPACING);
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params = _params(address(0), address(0), BASE_FEE, hex"", false);
        params.poolParameters.tickSpacing = tickSpacing;

        vm.expectRevert(
            abi.encodeWithSelector(
                IDirectLaunchStrategy.InvalidTickSpacing.selector,
                tickSpacing,
                TickMath.MIN_TICK_SPACING,
                TickMath.MAX_TICK_SPACING
            )
        );
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_fuzz_WhenFeeIsAboveMax(uint24 fee) public {
        fee = uint24(bound(fee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));
        if (fee == LPFeeLibrary.DYNAMIC_FEE_FLAG) fee++;
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params = _params(address(0), address(0), fee, hex"", false);

        vm.expectRevert(
            abi.encodeWithSelector(IDirectLaunchStrategy.InvalidFee.selector, fee, LPFeeLibrary.MAX_LP_FEE)
        );
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_WhenFeeIsDynamicFeeFlagWithoutHook() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params =
            _params(address(0), address(0), LPFeeLibrary.DYNAMIC_FEE_FLAG, hex"", false);

        vm.expectRevert(IDirectLaunchStrategy.InvalidDynamicFeeHook.selector);
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_WhenRecipientIsZeroAddress() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params = _params(address(0), address(0), BASE_FEE, hex"", false);
        params.recipient = address(0);

        vm.expectRevert(IDirectLaunchStrategy.InvalidRecipient.selector);
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_fuzz_WhenPositionRecipientIsReserved(uint256 seed) public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params = _params(address(0), address(0), BASE_FEE, hex"", false);
        params.positionRecipient =
            seed % 3 == 0 ? address(0) : seed % 3 == 1 ? ActionConstants.MSG_SENDER : ActionConstants.ADDRESS_THIS;

        vm.expectRevert(
            abi.encodeWithSelector(IDirectLaunchStrategy.InvalidPositionRecipient.selector, params.positionRecipient)
        );
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_fuzz_WhenWeightsDoNotSumToMPS(uint24 weight) public {
        weight = uint24(bound(weight, 1, PositionPlanner.MPS - 1));
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);

        PositionDefinition[] memory definitions = new PositionDefinition[](1);
        definitions[0] = PositionDefinition({
            offsetLower: -10 * TICK_SPACING, offsetUpper: 0, weight: weight, overridePositionRecipient: address(0)
        });
        DirectLaunchParameters memory params =
            _paramsWithDefinitions(address(0), address(0), BASE_FEE, hex"", definitions);

        vm.expectRevert(abi.encodeWithSelector(IDirectLaunchStrategy.IncompleteAllocation.selector, weight));
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_WhenPositionDefinitionsAreEmpty() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params =
            _paramsWithDefinitions(address(0), address(0), BASE_FEE, hex"", new PositionDefinition[](0));

        vm.expectRevert(abi.encodeWithSelector(IDirectLaunchStrategy.IncompleteAllocation.selector, 0));
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_WhenPositionIsNotSingleSided() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        // The token orders as currency1 against native currency, so a range above the tick is currency-side.
        PositionDefinition[] memory definitions = new PositionDefinition[](1);
        definitions[0] = PositionDefinition({
            offsetLower: 0, offsetUpper: 10 * TICK_SPACING, weight: 1e7, overridePositionRecipient: address(0)
        });
        DirectLaunchParameters memory params =
            _paramsWithDefinitions(address(0), address(0), BASE_FEE, hex"", definitions);

        vm.expectRevert(abi.encodeWithSelector(PositionPlanner.PositionNotSingleSided.selector, 0, 10 * TICK_SPACING));
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_fuzz_WhenHookAuthorizedAddressIsNotStrategy(address authorized) public {
        vm.assume(authorized != address(strategy));
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        address hook = address(new MockInitializerHook(authorized));
        DirectLaunchParameters memory params = _params(address(0), hook, BASE_FEE, hex"", false);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, hook));
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_WhenPoolIsAlreadyInitialized() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params = _params(address(0), address(0), BASE_FEE, hex"", false);

        POOL_MANAGER.initialize(_poolKey(address(token), params), TickMath.getSqrtPriceAtTick(0));

        token.approve(address(strategy), DEFAULT_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, address(0)));
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_WhenLaunchHookWithoutLaunchConfig() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params =
            _params(address(0), address(launchHook), LPFeeLibrary.DYNAMIC_FEE_FLAG, hex"", false);

        vm.expectRevert(IDirectLaunchStrategy.MissingLaunchConfig.selector);
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_WhenHooklessWithLaunchConfig() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        DirectLaunchParameters memory params =
            _params(address(0), address(0), BASE_FEE, _gateOnlyLaunchConfig(0), false);

        vm.expectRevert(IDirectLaunchStrategy.UnexpectedLaunchConfig.selector);
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));
    }

    function test_WhenLaunchHookWithValidConfig_registersConfig() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        bytes memory launchConfig = _gateOnlyLaunchConfig(uint48(block.number + 5));
        DirectLaunchParameters memory params =
            _params(address(0), address(launchHook), LPFeeLibrary.DYNAMIC_FEE_FLAG, launchConfig, false);
        PoolId poolId = _poolKey(address(token), params).toId();

        _launch(token, DEFAULT_SUPPLY, params);

        assertTrue(launchHook.isConfigured(poolId));
        LaunchConfig memory stored = launchHook.launchConfig(poolId);
        assertEq(stored.module, address(0));
        assertEq(stored.swapStartBlock, uint48(block.number + 5));
        assertEq(stored.windowEndBlock, uint48(block.number + 5));
        assertEq(stored.baseFee, BASE_FEE);
        // The helper encodes tokenIsCurrency0 = true; the strategy overwrites it with the derived ordering
        // (the token orders as currency1 against native currency).
        assertFalse(stored.tokenIsCurrency0);
    }

    function test_WhenParamsAreValid_initializesPoolAndMintsPositions() public {
        MockERC20 token = _deployToken(DEFAULT_SUPPLY);
        address override1 = makeAddr("override1");
        PositionDefinition[] memory definitions = _defaultDefinitions(false);
        definitions[1].overridePositionRecipient = override1;
        DirectLaunchParameters memory params =
            _paramsWithDefinitions(address(0), address(0), BASE_FEE, hex"", definitions);
        PoolKey memory key = _poolKey(address(token), params);

        uint256 nextTokenId = _positionManager().nextTokenId();

        token.approve(address(strategy), DEFAULT_SUPPLY);
        vm.expectEmit(true, true, false, false, address(strategy));
        emit IDirectLaunchStrategy.TokenLaunched(key.toId(), address(token), key, params.initialSqrtPriceX96, hex"");
        strategy.initializeDistribution(address(token), DEFAULT_SUPPLY, abi.encode(params), bytes32(0));

        // pool initialized at the configured price
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(sqrtPriceX96, params.initialSqrtPriceX96);

        // one position per definition, minted to the resolved recipients
        assertEq(_positionManager().nextTokenId(), nextTokenId + 2);
        assertEq(_positionManager().ownerOf(nextTokenId), positionRecipient);
        assertEq(_positionManager().ownerOf(nextTokenId + 1), override1);
        assertGt(_positionManager().getPositionLiquidity(nextTokenId), 0);
        assertGt(_positionManager().getPositionLiquidity(nextTokenId + 1), 0);

        // allowance fully consumed and nothing stranded on the strategy
        assertEq(token.allowance(address(this), address(strategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);

        // placed supply and swept dust account for the entire distribution
        assertEq(token.balanceOf(address(POOL_MANAGER)) + token.balanceOf(recipient), DEFAULT_SUPPLY);
    }

    function test_fuzz_WhenParamsAreValid_placesEntireSupply(uint128 totalSupply, uint24 weight) public {
        totalSupply = uint128(bound(totalSupply, 1 ether, uint128(1e33)));
        weight = uint24(bound(weight, 1e6, 9e6));

        MockERC20 token = _deployToken(totalSupply);
        PositionDefinition[] memory definitions = _defaultDefinitions(false);
        definitions[0].weight = weight;
        definitions[1].weight = PositionPlanner.MPS - weight;
        DirectLaunchParameters memory params =
            _paramsWithDefinitions(address(0), address(0), BASE_FEE, hex"", definitions);

        _launch(token, totalSupply, params);

        assertEq(token.allowance(address(this), address(strategy)), 0);
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(POOL_MANAGER)) + token.balanceOf(recipient), totalSupply);
        assertGt(token.balanceOf(address(POOL_MANAGER)), 0);
    }

    function test_WhenTokenIsCurrency0_mintsPositionsAbovePrice() public {
        // Deploy two ERC20s and list the lower-ordered one against the higher-ordered one.
        MockERC20 a = _deployToken(DEFAULT_SUPPLY);
        MockERC20 b = _deployToken(DEFAULT_SUPPLY);
        (MockERC20 token, MockERC20 currency) = address(a) < address(b) ? (a, b) : (b, a);

        DirectLaunchParameters memory params = _params(address(currency), address(0), BASE_FEE, hex"", true);

        uint256 nextTokenId = _positionManager().nextTokenId();
        _launch(token, DEFAULT_SUPPLY, params);

        assertEq(_positionManager().nextTokenId(), nextTokenId + 2);
        assertEq(token.balanceOf(address(strategy)), 0);
        assertEq(token.balanceOf(address(POOL_MANAGER)) + token.balanceOf(recipient), DEFAULT_SUPPLY);
    }
}
