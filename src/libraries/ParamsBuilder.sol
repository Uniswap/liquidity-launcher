// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {FullRangeParams, OneSidedParams} from "../types/PositionTypes.sol";
import {TickBounds} from "../types/PositionTypes.sol";

/// @title ParamsBuilder
/// @notice Library for building position parameters
library ParamsBuilder {
    error InvalidParamsLength(uint256 invalidLength);

    /// @notice Empty bytes used as hook data when minting positions since no hook data is needed
    bytes constant ZERO_BYTES = new bytes(0);

    /// @notice Number of params needed for a standalone full-range position
    ///         (1. mint, 2. settle, 3. settle, 4. take pair)
    uint256 public constant FULL_RANGE_SIZE = 4;

    /// @notice Number of params needed for full-range + one-sided position
    ///         (1. mint, 2. settle, 3. settle, 4. mint, 5. take pair)
    uint256 public constant FULL_RANGE_WITH_ONE_SIDED_SIZE = 5;

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
        address positionRecipient,
        uint128 liquidity
    ) internal pure returns (bytes[] memory params) {
        if (paramsArraySize != FULL_RANGE_SIZE && paramsArraySize != FULL_RANGE_WITH_ONE_SIDED_SIZE) {
            revert InvalidParamsLength(paramsArraySize);
        }

        // Build parameters
        params = new bytes[](paramsArraySize);

        uint128 amount0 = currencyIsCurrency0 ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount;
        uint128 amount1 = currencyIsCurrency0 ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount;

        // Set up mint
        params[0] = abi.encode(
            poolKey, bounds.lowerTick, bounds.upperTick, liquidity, amount0, amount1, positionRecipient, ZERO_BYTES
        );

        // Send the position manager's full balance of both currencies to cover both positions
        // This includes any pre-existing tokens in the position manager, which will be sent to the pool manager
        // and ultimately transferred to the LBP contract at the end.
        // Set up settlement for currency0
        params[1] = abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false); // payerIsUser is false because position manager will be the payer
        // Set up settlement for currency1
        params[2] = abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false); // payerIsUser is false because position manager will be the payer

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
        address positionRecipient,
        uint128 liquidity
    ) internal pure returns (bytes[] memory) {
        if (existingParams.length != FULL_RANGE_WITH_ONE_SIDED_SIZE) {
            revert InvalidParamsLength(existingParams.length);
        }

        // Determine which currency (0 or 1) receives the one-sided liquidity amount
        // XOR logic: position uses currency1 when:
        //   - currencyIsCurrency0=true AND inToken=true (currency is 0, position in token which is 1)
        //   - currencyIsCurrency0=false AND inToken=false (currency is 1, position in currency which is 1)
        bool useAmountInCurrency1 = currencyIsCurrency0 == oneSidedParams.inToken;

        // Set the amount to the appropriate currency slot
        uint256 amount0 = useAmountInCurrency1 ? 0 : oneSidedParams.amount;
        uint256 amount1 = useAmountInCurrency1 ? oneSidedParams.amount : 0;

        // Set up mint for token
        existingParams[FULL_RANGE_SIZE - 1] = abi.encode(
            poolKey, bounds.lowerTick, bounds.upperTick, liquidity, amount0, amount1, positionRecipient, ZERO_BYTES
        );

        return existingParams;
    }

    /// @notice Builds the parameters needed to take the pair using the position manager
    /// @param currency0 The currency0 address
    /// @param currency1 The currency1 address
    /// @param existingParams Params to create a full range position (Output of buildFullRangeParams() or buildOneSidedParams())
    /// @return params The parameters needed to take the pair using the position manager
    function buildFinalTakePairParams(address currency0, address currency1, bytes[] memory existingParams)
        internal
        view
        returns (bytes[] memory)
    {
        if (existingParams.length != FULL_RANGE_SIZE && existingParams.length != FULL_RANGE_WITH_ONE_SIDED_SIZE) {
            revert InvalidParamsLength(existingParams.length);
        }

        // Take any open deltas from the pool manager and send back to the lbp
        existingParams[existingParams.length - 1] =
            abi.encode(Currency.wrap(currency0), Currency.wrap(currency1), address(this));

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
