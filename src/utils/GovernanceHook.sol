// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BaseHook} from "./HookBasic.sol";

contract GovernanceHook is BaseHook {
    /// @notice Emitted when migration is approved by governance
    event MigrationApproved();
    /// @notice Emitted when the governance contract is set
    event GovernanceSet(address governance);
    /// @notice Error thrown when the initializer of the pool is not the strategy contract
    error InvalidInitializer(address caller, address strategy);

    /// @notice Error thrown when migration is not approved by governance
    error MigrationNotApproved();
    /// @notice Error thrown when the caller is not the governance contract
    error NotGovernance();

    /// @notice The address of the governance contract
    address public immutable governance;

    /// @notice Whether migration is approved by governance
    bool public isMigrationApproved;

    constructor(IPoolManager _poolManager, address _governance) BaseHook(_poolManager) {
        governance = _governance;
        emit GovernanceSet(governance);
    }


    /// @notice Approves migration by governance
    function approveMigration() external {
        if (msg.sender != governance) revert NotGovernance();
        isMigrationApproved = true;
        emit MigrationApproved();
    }

    /// @inheritdoc BaseHook
    function _beforeInitialize(address sender, PoolKey calldata, uint160) internal view override returns (bytes4) {
        // This check is only hit when another address tries to initialize the pool, since hooks cannot call themselves.
        // Therefore this will always revert, ensuring only this contract can initialize pools
        if (sender != address(this)) revert InvalidInitializer(sender, address(this));
        if (!isMigrationApproved) revert MigrationNotApproved();

        return IHooks.beforeInitialize.selector;
    }
}