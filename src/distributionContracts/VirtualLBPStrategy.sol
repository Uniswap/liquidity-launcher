// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullRangeLBPStrategy} from "./FullRangeLBPStrategy.sol";
import {IVirtualERC20} from "../interfaces/external/IVirtualERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {MigratorParameters} from "../types/MigratorParameters.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title VirtualLBPStrategyBasic
/// @notice Strategy for distributing virtual tokens to a v4 pool
/// Virtual tokens are ERC20 tokens that wrap an underlying token.
contract VirtualFullRangeLBPStrategy is FullRangeLBPStrategy {
    /// @notice Emitted when migration is approved by the governance address
    event MigrationApproved();
    /// @notice Emitted when the governance address is set
    /// @param governance The address of the governance address
    event GovernanceSet(address governance);

    /// @notice Error thrown when migration is not approved yet by the governance address
    error MigrationNotApproved();
    /// @notice Error thrown when the caller is not the governance address
    error NotGovernance();

    /// @notice The address of Aztec Governance
    address public immutable GOVERNANCE;

    /// @notice The address of the underlying token that is being distributed - used in the migrated pool
    address public immutable UNDERLYING_TOKEN;

    /// @notice Whether migration is approved by Governance
    bool public isMigrationApproved = false;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _auctionParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        address _governance
    )
        // Underlying strategy
        FullRangeLBPStrategy(_token, _totalSupply, _migratorParams, _auctionParams, _positionManager, _poolManager)
    {
        UNDERLYING_TOKEN = IVirtualERC20(_token).UNDERLYING_TOKEN_ADDRESS();
        GOVERNANCE = _governance;
        emit GovernanceSet(_governance);
    }

    /// @notice Approves migration of the virtual token to the v4 pool
    /// @dev Only callable by the governance address
    function approveMigration() external {
        if (msg.sender != GOVERNANCE) revert NotGovernance();
        isMigrationApproved = true;
        emit MigrationApproved();
    }

    /// @notice Returns the permissions for the hook
    /// @dev Has permissions for before initialize, before swap and before remove liquidity
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
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

    /// @notice Validates that migration is approved before swapping on the pool and returns a zero delta
    /// @dev Reverts if migration is not approved
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!isMigrationApproved) revert MigrationNotApproved();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Returns the address of the underlying token
    function getPoolToken() internal view override returns (address) {
        return UNDERLYING_TOKEN;
    }
}
