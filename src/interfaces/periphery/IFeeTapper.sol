// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Struct representing an active tap for a given currency
struct Tap {
    uint128 balance; /// @notice The last synced balance of the tap
    uint32 head; /// @notice The head of the linked list of kegs
    uint32 tail; /// @notice The tail of the linked list of kegs
}

/// @notice Struct representing a unique currency deposit
struct Keg {
    uint128 perBlockReleaseAmount; /// @notice The absolute amount of the currency released per block
    uint48 endBlock; /// @notice The block at which the deposit will be fully released
    uint48 lastReleaseBlock; /// @notice The block at which the last release was made
    uint32 next; /// @notice The next keg in the linked list
}

/// @title IFeeTapper
interface IFeeTapper {
    /// @notice Error thrown when the amount is invalid
    error InvalidAmount();

    /// @notice Error thrown when the release rate is invalid
    error ReleaseRateOutOfBounds();

    /// @notice Error thrown when BPS is not evenly divisible by the release rate
    error InvalidReleaseRate();

    /// @notice Emitted when a new deposit is synced
    /// @param id The unique id of the deposit
    /// @param currency The currency being deposited
    /// @param amount The amount of protocol fees deposited
    /// @param endBlock The block at which the deposit will be fully released
    event Deposited(uint64 indexed id, address indexed currency, uint128 amount, uint64 endBlock);

    /// @notice Emitted when protocol fees are deposited
    event Synced(address indexed currency, uint128 amount);

    /// @notice Emitted when protocol fees are released
    event Released(address indexed currency, uint128 amount);

    /// @notice Emitted when the release rate is set
    /// @param perBlockReleaseRate The new release rate
    event ReleaseRateSet(uint24 perBlockReleaseRate);

    /// @notice Syncs the fee tapper with received protocol fees
    /// @param currency The currency to sync
    function sync(Currency currency) external;

    /// @notice Releases any accrued protocol fees to the protocol fee recipient
    /// @param currency The currency to release
    /// @return amount The amount of protocol fees released
    function release(Currency currency) external returns (uint128);
}
