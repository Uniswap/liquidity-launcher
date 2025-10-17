// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FullRangeParams, OneSidedParams} from "../types/PositionTypes.sol";
import {TickBounds} from "../types/PositionTypes.sol";

/// @title ParamsBuilder
/// @notice Library for building position parameters
library ParamsBuilder {
    error InvalidParamsLength(uint256 invalidLength);

    /// @notice Empty bytes used as hook data when minting positions since no hook data is needed
    bytes constant ZERO_BYTES = new bytes(0);

    /// @notice Number of params needed for a standalone full-range position
    uint256 public constant FULL_RANGE_SIZE = 5;

    /// @notice Number of params needed for full-range + one-sided position
    uint256 public constant FULL_RANGE_WITH_ONE_SIDED_SIZE = 8;

    /// @notice Builds the parameters needed to mint a full range position using the position manager
    /// @param fullRangeParams The amounts of currency and token that will be used to mint the position
    /// @param poolKey The pool key
    /// @param bounds The tick bounds for the full range position
    /// @param currencyIsCurrency0 Whether the currency address is less than the token address
    /// @param paramsArraySize The size of the parameters array (either 5 or 8)
    /// @param positionRecipient The recipient of the position
    /// @return params The parameters needed to mint a full range position using the position manager
    function buildFullRangeParams(
        FullRangeParams memory fullRangeParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        uint256 paramsArraySize,
        address positionRecipient
    ) internal pure returns (bytes[] memory params) {
        if (paramsArraySize != FULL_RANGE_SIZE && paramsArraySize != FULL_RANGE_WITH_ONE_SIDED_SIZE) {
            revert InvalidParamsLength(paramsArraySize);
        }

        // Build parameters - direct encoding to avoid stack issues
        params = new bytes[](paramsArraySize);

        uint256 amount0 = currencyIsCurrency0 ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount;
        uint256 amount1 = currencyIsCurrency0 ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount;

        // Settlement params
        params[0] = abi.encode(poolKey.currency0, amount0, false); // payerIsUser is false because position manager will be the payer
        params[1] = abi.encode(poolKey.currency1, amount1, false); // payerIsUser is false because position manager will be the payer

        // Mint from deltas params
        params[2] =
            abi.encode(poolKey, bounds.lowerTick, bounds.upperTick, amount0, amount1, positionRecipient, ZERO_BYTES);

        // Clear params
        params[3] = abi.encode(poolKey.currency0, type(uint256).max);
        params[4] = abi.encode(poolKey.currency1, type(uint256).max);

        return params;
    }

    /// @notice Builds the parameters needed to mint a one-sided position using the position manager
    /// @param oneSidedParams The data specific to creating the one-sided position
    /// @param poolKey The pool key
    /// @param bounds The tick bounds for the one-sided position
    /// @param currencyIsCurrency0 Whether the currency address is less than the token address
    /// @param existingParams Params to create a full range position (Output of buildFullRangeParams())
    /// @param currencyIsCurrency0 Whether the currency address is less than the token address
    /// @param existingParams Params to create a full range position (Output of buildFullRangeParams())
    /// @param positionRecipient The recipient of the position
    /// @return params The parameters needed to mint a one-sided position using the position manager
    function buildOneSidedParams(
        OneSidedParams memory oneSidedParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        bytes[] memory existingParams,
        address positionRecipient
    ) internal pure returns (bytes[] memory) {
        if (existingParams.length != FULL_RANGE_WITH_ONE_SIDED_SIZE) {
            revert InvalidParamsLength(existingParams.length);
        }

        // Set up settlement for token
        existingParams[FULL_RANGE_SIZE] = abi.encode(
            currencyIsCurrency0 == oneSidedParams.inToken ? poolKey.currency1 : poolKey.currency0,
            oneSidedParams.amount,
            false // payerIsUser is false because position manager will be the payer
        );

        // Set up mint params directly
        existingParams[FULL_RANGE_SIZE + 1] = abi.encode(
            poolKey,
            bounds.lowerTick,
            bounds.upperTick,
            currencyIsCurrency0 == oneSidedParams.inToken ? 0 : oneSidedParams.amount,
            currencyIsCurrency0 == oneSidedParams.inToken ? oneSidedParams.amount : 0,
            positionRecipient,
            ZERO_BYTES
        );

        // Set up clear params
        existingParams[FULL_RANGE_SIZE + 2] = abi.encode(
            currencyIsCurrency0 == oneSidedParams.inToken ? poolKey.currency1 : poolKey.currency0, type(uint256).max
        );

        return existingParams;
    }

    /// @notice Truncates parameters array to full-range only size (5 params)
    /// @param params The parameters to truncate
    /// @return truncated The truncated parameters only (5 params)
    function truncateParams(bytes[] memory params) internal pure returns (bytes[] memory) {
        bytes[] memory truncated = new bytes[](FULL_RANGE_SIZE);
        for (uint256 i = 0; i < FULL_RANGE_SIZE; i++) {
            truncated[i] = params[i];
        }
        return truncated;
    }
}
