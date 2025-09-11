// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullRangeParams, OneSidedParams} from "../types/PositionTypes.sol";
import {TickBounds} from "../types/PositionTypes.sol";
import "forge-std/console2.sol";

/// @title ParamsBuilder
/// @notice Library for building position parameters
library ParamsBuilder {
    error InvalidParamsLength(uint256 invalidLength);

    bytes constant ZERO_BYTES = new bytes(0);

    /// @notice Number of params needed for a standalone full-range position
    uint256 public constant FULL_RANGE_ONLY_PARAMS = 5;

    /// @notice Number of params needed for full-range + one-sided position
    uint256 public constant FULL_RANGE_WITH_ONE_SIDED_PARAMS = 8;

    function buildFullRangeParams(
        FullRangeParams memory fullRangeParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        uint256 paramsArraySize,
        address positionRecipient
    ) internal pure returns (bytes[] memory params) {
        if (paramsArraySize != FULL_RANGE_ONLY_PARAMS && paramsArraySize != FULL_RANGE_WITH_ONE_SIDED_PARAMS) {
            revert InvalidParamsLength(paramsArraySize);
        }

        // Build parameters - direct encoding to avoid stack issues
        params = new bytes[](paramsArraySize);

        uint128 amount0 = currencyIsCurrency0 ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount;
        uint128 amount1 = currencyIsCurrency0 ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount;

        // Settlement params
        params[0] = abi.encode(poolKey.currency0, amount0, false);
        params[1] = abi.encode(poolKey.currency1, amount1, false);

        // Mint from deltas params
        params[2] =
            abi.encode(poolKey, bounds.lowerTick, bounds.upperTick, amount0, amount1, positionRecipient, ZERO_BYTES);

        // Clear params
        params[3] = abi.encode(poolKey.currency0, type(uint256).max);
        params[4] = abi.encode(poolKey.currency1, type(uint256).max);

        return params;
    }

    function buildOneSidedParams(
        OneSidedParams memory oneSidedParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        bytes[] memory existingParams,
        address positionRecipient
    ) internal pure returns (bytes[] memory) {
        if (existingParams.length != FULL_RANGE_WITH_ONE_SIDED_PARAMS) {
            revert InvalidParamsLength(existingParams.length);
        }

        // Set up settlement for token
        existingParams[FULL_RANGE_ONLY_PARAMS] = abi.encode(
            currencyIsCurrency0 == oneSidedParams.inToken ? poolKey.currency1 : poolKey.currency0,
            oneSidedParams.amount,
            false
        );

        // Set up mint params directly
        existingParams[FULL_RANGE_ONLY_PARAMS + 1] = abi.encode(
            poolKey,
            bounds.lowerTick,
            bounds.upperTick,
            currencyIsCurrency0 == oneSidedParams.inToken ? 0 : oneSidedParams.amount,
            currencyIsCurrency0 == oneSidedParams.inToken ? oneSidedParams.amount : 0,
            positionRecipient,
            ZERO_BYTES
        );

        // Set up clear params
        existingParams[FULL_RANGE_ONLY_PARAMS + 2] = abi.encode(
            currencyIsCurrency0 == oneSidedParams.inToken ? poolKey.currency1 : poolKey.currency0, type(uint256).max
        );

        return existingParams;
    }

    /// @notice Truncates parameters array to full-range only size
    function truncateParams(bytes[] memory params) internal pure returns (bytes[] memory) {
        bytes[] memory truncated = new bytes[](FULL_RANGE_ONLY_PARAMS);
        for (uint256 i = 0; i < FULL_RANGE_ONLY_PARAMS; i++) {
            truncated[i] = params[i];
        }
        return truncated;
    }
}
