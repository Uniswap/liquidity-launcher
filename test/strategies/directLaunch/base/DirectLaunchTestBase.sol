// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {DirectLaunchStrategy} from "../../../../src/strategies/DirectLaunchStrategy.sol";
import {DirectLaunchParameters} from "../../../../src/libraries/DirectLaunchParams.sol";
import {PoolParameters} from "../../../../src/libraries/MigratorParams.sol";
import {LaunchHook} from "../../../../src/periphery/hooks/LaunchHook.sol";
import {LaunchConfig} from "../../../../src/interfaces/ILaunchHook.sol";
import {DutchDecayFeeModule, DutchDecayConfig} from "../../../../src/periphery/modules/DutchDecayFeeModule.sol";
import {PositionDefinition} from "../../../../src/types/PositionPlannerTypes.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// PoolManager is imported so its artifact is compiled for deployCodeTo
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Shared local v4 setup for DirectLaunchStrategy tests
abstract contract DirectLaunchTestBase is Test {
    // Canonical v4 deployment addresses.
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    int24 constant TICK_SPACING = 60;
    uint24 constant BASE_FEE = 3000;
    uint128 constant DEFAULT_SUPPLY = 1_000_000 ether;

    DirectLaunchStrategy strategy;
    LaunchHook launchHook;
    DutchDecayFeeModule dutchModule;

    address recipient = makeAddr("recipient");
    address positionRecipient = makeAddr("positionRecipient");

    function setUp() public virtual {
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(0)),
            address(POSITION_MANAGER)
        );

        strategy = new DirectLaunchStrategy(POSITION_MANAGER, POOL_MANAGER);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG,
            type(LaunchHook).creationCode,
            abi.encode(POOL_MANAGER, address(strategy))
        );
        launchHook = new LaunchHook{salt: salt}(POOL_MANAGER, address(strategy));
        assertEq(address(launchHook), hookAddress);

        dutchModule = new DutchDecayFeeModule();
    }

    /// @notice Returns two token-side tiers relative to an initial tick of zero
    function _defaultDefinitions(bool tokenIsCurrency0) internal pure returns (PositionDefinition[] memory) {
        PositionDefinition[] memory definitions = new PositionDefinition[](2);
        if (tokenIsCurrency0) {
            definitions[0] = PositionDefinition({
                offsetLower: 0, offsetUpper: 10 * TICK_SPACING, weight: 6e6, overridePositionRecipient: address(0)
            });
            definitions[1] = PositionDefinition({
                offsetLower: 10 * TICK_SPACING,
                offsetUpper: 20 * TICK_SPACING,
                weight: 4e6,
                overridePositionRecipient: address(0)
            });
        } else {
            definitions[0] = PositionDefinition({
                offsetLower: -10 * TICK_SPACING, offsetUpper: 0, weight: 6e6, overridePositionRecipient: address(0)
            });
            definitions[1] = PositionDefinition({
                offsetLower: -20 * TICK_SPACING,
                offsetUpper: -10 * TICK_SPACING,
                weight: 4e6,
                overridePositionRecipient: address(0)
            });
        }
        return definitions;
    }

    function _params(address currency, address hook, uint24 fee, bytes memory launchConfig, bool tokenIsCurrency0)
        internal
        view
        returns (DirectLaunchParameters memory)
    {
        return _paramsWithDefinitions(currency, hook, fee, launchConfig, _defaultDefinitions(tokenIsCurrency0));
    }

    function _paramsWithDefinitions(
        address currency,
        address hook,
        uint24 fee,
        bytes memory launchConfig,
        PositionDefinition[] memory definitions
    ) internal view returns (DirectLaunchParameters memory) {
        return DirectLaunchParameters({
            currency: currency,
            initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
            recipient: recipient,
            positionRecipient: positionRecipient,
            poolParameters: PoolParameters({fee: fee, tickSpacing: TICK_SPACING, hook: hook}),
            positionDefinitions: abi.encode(definitions),
            launchConfig: launchConfig
        });
    }

    /// @notice Returns a gated launch configuration with a Dutch-decay fee window
    /// @dev `tokenIsCurrency0` is intentionally wrong to verify that the strategy overwrites it.
    function _launchConfig(uint48 swapStartBlock, uint48 windowEndBlock, DutchDecayConfig memory config)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            LaunchConfig({
                swapStartBlock: swapStartBlock,
                windowEndBlock: windowEndBlock,
                baseFee: BASE_FEE,
                tokenIsCurrency0: true,
                module: address(dutchModule),
                moduleConfig: abi.encode(config)
            })
        );
    }

    /// @notice Returns a moduleless launch configuration with a base fee
    /// @dev `tokenIsCurrency0` is intentionally wrong to verify that the strategy overwrites it.
    function _gateOnlyLaunchConfig(uint48 swapStartBlock) internal pure returns (bytes memory) {
        return abi.encode(
            LaunchConfig({
                swapStartBlock: swapStartBlock,
                windowEndBlock: swapStartBlock,
                baseFee: BASE_FEE,
                tokenIsCurrency0: true,
                module: address(0),
                moduleConfig: bytes("")
            })
        );
    }

    function _deployToken(uint128 supply) internal returns (MockERC20) {
        return new MockERC20("Test Token", "TT", supply, address(this));
    }

    function _launch(MockERC20 token, uint128 supply, DirectLaunchParameters memory params) internal {
        token.approve(address(strategy), supply);
        strategy.initializeDistribution(address(token), supply, abi.encode(params), bytes32(0));
    }

    function _poolKey(address token, DirectLaunchParameters memory params) internal pure returns (PoolKey memory) {
        Currency t = Currency.wrap(token);
        Currency c = Currency.wrap(params.currency);
        return PoolKey({
            currency0: t < c ? t : c,
            currency1: t < c ? c : t,
            fee: params.poolParameters.fee,
            tickSpacing: params.poolParameters.tickSpacing,
            hooks: IHooks(params.poolParameters.hook)
        });
    }

    function _positionManager() internal pure returns (PositionManager) {
        return PositionManager(payable(address(POSITION_MANAGER)));
    }
}
