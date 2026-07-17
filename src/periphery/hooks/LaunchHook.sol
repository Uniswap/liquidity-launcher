// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {InitializerHook} from "./InitializerHook.sol";
import {ILaunchHook, LaunchConfig} from "../../interfaces/ILaunchHook.sol";
import {IDynamicFeeModule} from "../../interfaces/IDynamicFeeModule.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title LaunchHook
/// @notice Gates pool initialization and applies module-quoted LP fees during a launch window
/// @dev The authorized strategy registers each pool exactly once before initialization. Fee modules are trusted:
///      a module failure reverts the affected swap during its configured window.
contract LaunchHook is InitializerHook, BlockNumberish, ILaunchHook {
    using LPFeeLibrary for uint24;

    /// @notice The launch configuration registered for each pool
    mapping(PoolId poolId => LaunchConfig config) internal _launchConfigs;

    /// @inheritdoc ILaunchHook
    mapping(PoolId poolId => bool configured) public isConfigured;

    constructor(IPoolManager _poolManager, address _authorized) InitializerHook(_poolManager, _authorized) {}

    /// @inheritdoc ILaunchHook
    function setLaunchConfig(PoolId poolId, LaunchConfig calldata config) external {
        if (msg.sender != authorized) revert NotAuthorized(msg.sender, authorized);
        if (isConfigured[poolId]) revert LaunchConfigAlreadySet(poolId);
        if (config.windowEndBlock < config.swapStartBlock) {
            revert InvalidWindow(config.swapStartBlock, config.windowEndBlock);
        }
        if (config.baseFee > LPFeeLibrary.MAX_LP_FEE) revert InvalidBaseFee(config.baseFee);

        _launchConfigs[poolId] = config;
        isConfigured[poolId] = true;

        emit LaunchConfigSet(poolId, config);
    }

    /// @inheritdoc ILaunchHook
    function launchConfig(PoolId poolId) external view returns (LaunchConfig memory) {
        return _launchConfigs[poolId];
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            beforeAddLiquidity: false,
            beforeSwap: true,
            beforeSwapReturnDelta: false,
            afterSwap: false,
            afterInitialize: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeDonate: false,
            afterDonate: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        bytes4 selector = super._beforeInitialize(sender, key, sqrtPriceX96);
        // v4 only applies fee overrides to dynamic-fee pools.
        if (!key.fee.isDynamicFee()) revert NotDynamicFee(key.fee);
        PoolId poolId = key.toId();
        if (!isConfigured[poolId]) revert LaunchConfigNotSet(poolId);

        address module = _launchConfigs[poolId].module;
        if (module != address(0)) {
            (bool success, bytes memory returnData) = module.staticcall(abi.encodeCall(IDynamicFeeModule.getFee, (key)));
            if (!success || returnData.length < 64) revert InvalidModule(module);
        }
        return selector;
    }

    /// @inheritdoc BaseHook
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        LaunchConfig storage config = _launchConfigs[key.toId()];
        uint256 currentBlock = _getBlockNumberish();
        if (currentBlock < config.swapStartBlock) revert SwapsNotStarted(config.swapStartBlock, currentBlock);

        uint24 fee = config.baseFee;
        if (currentBlock < config.windowEndBlock) {
            address module = config.module;
            if (module != address(0)) {
                // Module failures block swaps until the launch window ends.
                (uint24 zeroForOneFee, uint24 oneForZeroFee) = IDynamicFeeModule(module).getFee(key);
                fee = params.zeroForOne ? zeroForOneFee : oneForZeroFee;
                if (fee > LPFeeLibrary.MAX_LP_FEE) fee = LPFeeLibrary.MAX_LP_FEE;
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override(IERC165, InitializerHook) returns (bool) {
        return interfaceId == type(ILaunchHook).interfaceId || super.supportsInterface(interfaceId);
    }
}
