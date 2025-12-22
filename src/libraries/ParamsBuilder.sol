// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {FullRangeParams, OneSidedParams, TickBounds} from "../types/PositionTypes.sol";
import {DynamicArray} from "./DynamicArray.sol";

/// @title ParamsBuilder
/// @notice Library for building position parameters
library ParamsBuilder {
    using DynamicArray for bytes[];

    /// @notice Empty bytes used as hook data when minting positions since no hook data is needed
    bytes constant ZERO_BYTES = new bytes(0);

    /// @notice Initializes the parameters, allocating memory for maximum number of params
    function init() internal returns (bytes[] memory params) {
        return DynamicArray.init();
    }

    /// @notice Builds the parameters needed to mint a full range position using the position manager
    /// @param params The parameters array to populate
    /// @param fullRangeParams The amounts of currency and token that will be used to mint the position
    /// @param poolKey The pool key
    /// @param bounds The tick bounds for the full range position
    /// @param currencyIsCurrency0 Whether the currency address is less than the token address
    /// @param positionRecipient The recipient of the position
    /// @return params The parameters needed to mint a full range position using the position manager
    function addFullRangeParams(
        bytes[] memory params,
        FullRangeParams memory fullRangeParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        address positionRecipient,
        uint128 liquidity
    ) internal returns (bytes[] memory) {
        uint128 amount0 = currencyIsCurrency0 ? fullRangeParams.currencyAmount : fullRangeParams.tokenAmount;
        uint128 amount1 = currencyIsCurrency0 ? fullRangeParams.tokenAmount : fullRangeParams.currencyAmount;

        // Set up mint
        params = params.append(
            abi.encode(
                poolKey, bounds.lowerTick, bounds.upperTick, liquidity, amount0, amount1, positionRecipient, ZERO_BYTES
            )
        );

        // Send the position manager's full balance of both currencies to cover both positions
        // This includes any pre-existing tokens in the position manager, which will be sent to the pool manager
        // and ultimately transferred to the LBP contract at the end.
        // Set up settlement for currency0
        params = params.append(abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false)); // payerIsUser is false because position manager will be the payer
        // Set up settlement for currency1
        params = params.append(abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false)); // payerIsUser is false because position manager will be the payer

        return params;
    }

    /// @notice Builds the parameters needed to mint a one-sided position using the position manager
    /// @param params The parameters array to populate
    /// @param oneSidedParams The data specific to creating the one-sided position
    /// @param poolKey The pool key
    /// @param bounds The tick bounds for the one-sided position
    /// @param currencyIsCurrency0 Whether the currency address is less than the token address
    /// @param currencyIsCurrency0 Whether the currency address is less than the token address
    /// @param positionRecipient The recipient of the position
    /// @return params The parameters needed to mint a one-sided position using the position manager
    function addOneSidedParams(
        bytes[] memory params,
        OneSidedParams memory oneSidedParams,
        PoolKey memory poolKey,
        TickBounds memory bounds,
        bool currencyIsCurrency0,
        address positionRecipient,
        uint128 liquidity
    ) internal returns (bytes[] memory) {
        // Determine which currency (0 or 1) receives the one-sided liquidity amount
        // XOR logic: position uses currency1 when:
        //   - currencyIsCurrency0=true AND inToken=true (currency is 0, position in token which is 1)
        //   - currencyIsCurrency0=false AND inToken=false (currency is 1, position in currency which is 1)
        bool useAmountInCurrency1 = currencyIsCurrency0 == oneSidedParams.inToken;

        // Set the amount to the appropriate currency slot
        uint256 amount0 = useAmountInCurrency1 ? 0 : oneSidedParams.amount;
        uint256 amount1 = useAmountInCurrency1 ? oneSidedParams.amount : 0;

        // Set up mint for token
        return params.append(
            abi.encode(
                poolKey, bounds.lowerTick, bounds.upperTick, liquidity, amount0, amount1, positionRecipient, ZERO_BYTES
            )
        );
    }

    /// @notice Builds the parameters needed to take the pair using the position manager
    /// @param params The parameters array to populate
    /// @param currency0 The currency0 address
    /// @param currency1 The currency1 address
    /// @return params The parameters needed to take the pair using the position manager
    function addTakePairParams(bytes[] memory params, address currency0, address currency1)
        internal
        returns (bytes[] memory)
    {
        // Take any open deltas from the pool manager and send back to the lbp
        return params.append(abi.encode(Currency.wrap(currency0), Currency.wrap(currency1), address(this)));
    }
}
