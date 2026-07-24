// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockClaimExecutor} from "./MockClaimExecutor.sol";
import {IFeeSplitter} from "../../src/interfaces/IFeeSplitter.sol";

/// @title MockCompoundingClaimExecutor
/// @notice Deposits callback proceeds into PositionManager for compounding tests
contract MockCompoundingClaimExecutor is MockClaimExecutor {
    IPositionManager public immutable positionManager;
    IWETH9 public immutable weth9;
    IFeeSplitter public feeSplitter;
    uint256 public liquidityIncrease;

    constructor(IPositionManager _positionManager, IWETH9 _weth9) {
        positionManager = _positionManager;
        weth9 = _weth9;
    }

    function setFeeSplitter(IFeeSplitter _feeSplitter, uint256 _liquidityIncrease) external {
        feeSplitter = _feeSplitter;
        liquidityIncrease = _liquidityIncrease;
    }

    function onClaimed(PoolKey memory poolKey, uint256 tokenId, uint256 currency0Received, uint256 currency1Received)
        public
        override
    {
        super.onClaimed(poolKey, tokenId, currency0Received, currency1Received);

        if (poolKey.currency0.isAddressZero()) {
            if (currency0Received != 0) {
                weth9.deposit{value: currency0Received}();
                weth9.transfer(address(positionManager), currency0Received);
            }
        } else if (currency0Received != 0) {
            poolKey.currency0.transfer(address(positionManager), currency0Received);
        }

        if (currency1Received != 0) {
            poolKey.currency1.transfer(address(positionManager), currency1Received);
        }

        if (address(feeSplitter) != address(0)) {
            feeSplitter.increaseLiquidity(tokenId, liquidityIncrease, type(uint128).max, type(uint128).max, bytes(""));
        }
    }
}
