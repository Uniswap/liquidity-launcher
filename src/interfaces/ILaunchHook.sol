// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IInitializerHook} from "./IInitializerHook.sol";

/// @notice Per-pool configuration enforced by a launch hook
/// @dev Scalar fields are packed into one slot. The module is not read after the launch window.
struct LaunchConfig {
    uint48 swapStartBlock; // swaps revert before this block
    uint48 windowEndBlock; // the module is consulted while the block number is below this; baseFee applies after
    uint24 baseFee; // LP fee in pips applied outside the launch window
    bool tokenIsCurrency0; // whether the launched token is currency0 of the pool; stamped by the registering strategy
    address module; // IDynamicFeeModule consulted for fee overrides during the launch window; address(0) applies baseFee
    bytes moduleConfig; // opaque module parameters, readable by the module via launchConfig()
    bytes hookConfig; // opaque configuration interpreted by specialized launch hooks
}

/// @title ILaunchHook
/// @notice Configures swap start blocks and module-driven LP fees for launch pools
interface ILaunchHook is IInitializerHook {
    /// @notice Emitted when a launch configuration is registered for a pool
    /// @param poolId The pool the configuration applies to
    /// @param config The registered launch configuration
    event LaunchConfigSet(PoolId indexed poolId, LaunchConfig config);

    /// @notice Error thrown when the caller is not authorized to set a launch configuration
    /// @param caller The address that attempted the call
    /// @param expected The authorized address
    error NotAuthorized(address caller, address expected);

    /// @notice Error thrown when a launch configuration is already registered for the pool
    /// @param poolId The pool that is already configured
    error LaunchConfigAlreadySet(PoolId poolId);

    /// @notice Error thrown when a pool is initialized without a registered launch configuration
    /// @param poolId The unconfigured pool
    error LaunchConfigNotSet(PoolId poolId);

    /// @notice Error thrown when the launch window ends before it starts
    /// @param swapStartBlock The configured swap start block
    /// @param windowEndBlock The configured window end block
    error InvalidWindow(uint48 swapStartBlock, uint48 windowEndBlock);

    /// @notice Error thrown when the base fee exceeds the v4 max LP fee
    /// @param baseFee The invalid base fee
    error InvalidBaseFee(uint24 baseFee);

    /// @notice Error thrown when the pool key does not carry the dynamic fee flag
    /// @param fee The invalid pool fee
    error NotDynamicFee(uint24 fee);

    /// @notice Error thrown at pool initialization when the configured fee module cannot quote a fee
    error InvalidModule(address module);

    /// @notice Error thrown when a swap is attempted before the configured swap start block
    /// @param swapStartBlock The block at which swaps open
    /// @param currentBlock The current block number
    error SwapsNotStarted(uint256 swapStartBlock, uint256 currentBlock);

    /// @notice Registers a pool before initialization
    /// @dev May only be called once per pool by `authorized`.
    /// @param poolId The pool the configuration applies to
    /// @param config The launch configuration to register
    function setLaunchConfig(PoolId poolId, LaunchConfig calldata config) external;

    /// @notice The registered launch configuration for a pool
    /// @param poolId The pool to look up
    /// @return The stored launch configuration
    function launchConfig(PoolId poolId) external view returns (LaunchConfig memory);

    /// @notice Whether a launch configuration has been registered for a pool
    /// @param poolId The pool to look up
    function isConfigured(PoolId poolId) external view returns (bool);
}
