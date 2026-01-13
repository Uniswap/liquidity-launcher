// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Struct representing an active tap for a given currency
struct Tap {
    uint64 lastReleaseBlock; // The block number at which the last release occurred
    uint192 balance; // The last synced balance of the currency in the contract
}

/// @title IFeeTapper
interface IFeeTapper {
    /// @notice Error thrown when the amount is invalid
    error InvalidAmount();

    /// @notice Error thrown when the release rate is invalid
    error InvalidReleaseRate();

    /// @notice Emitted when protocol fees are deposited
    event Synced(address indexed currency, uint192 amount);

    /// @notice Emitted when protocol fees are released
    event Released(address indexed currency, uint192 amount);

    /// @notice Emitted when the release rate is set
    /// @param perBlockReleaseRate The new release rate
    event ReleaseRateSet(uint24 perBlockReleaseRate);

    /// @notice Syncs the fee tapper with received protocol fees
    /// @param currency The currency to sync
    function sync(Currency currency) external;

    /// @notice Releases any accrued protocol fees to the protocol fee recipient
    /// @param currency The currency to release
    /// @return amount The amount of protocol fees released
    function release(Currency currency) external returns (uint192);
}
