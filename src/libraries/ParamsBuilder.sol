// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {TickBounds} from "../types/PositionTypes.sol";

/// @title ParamsBuilder
/// @notice Library for building position parameters
library ParamsBuilder {
    /// @notice Empty bytes used as hook data when minting positions since no hook data is needed
    bytes constant ZERO_BYTES = new bytes(0);

    /// @notice Builds the parameters needed to mint a full range position using the position manager
    /// @param poolKey The pool key
    /// @param bounds The tick bounds for the full range position
    /// @param liquidity The liquidity for the full range position
    /// @param tokenAmount The amount of token to mint
    /// @param currencyAmount The amount of currency to mint
    /// @param positionRecipient The recipient of the position
    function addMintParam(
        PoolKey memory poolKey,
        TickBounds memory bounds,
        uint128 liquidity,
        uint128 tokenAmount,
        uint128 currencyAmount,
        address positionRecipient
    ) internal pure returns (bytes memory param) {
        bool currencyIsCurrency0 = poolKey.currency0 < poolKey.currency1;

        uint128 amount0 = currencyIsCurrency0 ? currencyAmount : tokenAmount;
        uint128 amount1 = currencyIsCurrency0 ? tokenAmount : currencyAmount;

        param = abi.encode(
            poolKey, bounds.lowerTick, bounds.upperTick, liquidity, amount0, amount1, positionRecipient, ZERO_BYTES
        );
    }

    function addSettleParam(Currency currency) internal pure returns (bytes memory param) {
        // Send the position manager's full balance of both currencies to cover both positions
        // This includes any pre-existing tokens in the position manager, which will be sent to the pool manager
        // and ultimately transferred to the LBP contract at the end.
        param = abi.encode(currency, ActionConstants.CONTRACT_BALANCE, false); // payerIsUser is false because position manager will be the payer
    }

    /// @notice Adds the parameter needed to take the pair using the position manager
    /// @param poolKey The pool key
    /// @return param The parameter needed to take the pair using the position manager
    function addTakePairParam(Currency currency0, Currency currency1) internal view returns (bytes memory param) {
        // Take any open deltas from the pool manager and send back to the lbp
        param = abi.encode(currency0, currency1, address(this));
    }
}
