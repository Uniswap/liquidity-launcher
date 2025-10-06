// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LBPStrategyBasicImpl} from "./LBPStrategyBasicImpl.sol";
import {HookBasic} from "../utils/HookBasic.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";

contract LBPStrategyBasic is LBPStrategyBasicImpl, HookBasic {
    constructor(
        address _token, 
        uint256 _totalSupply, 
        MigratorParameters memory _migratorParams, 
        bytes memory _auctionParams, 
        IPositionManager _positionManager, 
        IPoolManager _poolManager
    ) 
    // Underlying strategy
    LBPStrategyBasicImpl(_token, _totalSupply, _migratorParams, _auctionParams, _positionManager) 
    // Hook implementation
    HookBasic(_poolManager) {}
}