// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Struct representing an active tap for a given currency
struct Tap {
    uint128 balance;
    uint64 head;
    uint64 tail;
}

struct Keg {
    uint128 perBlockReleaseAmount;
    uint64 endBlock;
    uint64 lastReleaseBlock;
    uint64 next;
}

/// @title IFeeTapper
interface IFeeTapper {
    /// @notice Error thrown when the amount is invalid
    error InvalidAmount();

    /// @notice Error thrown when the release rate is invalid
    error InvalidReleaseRate();

    /// @notice Emitted when a tap is created
    event TapCreated(uint64 indexed id, address indexed currency, uint128 perBlockReleaseAmount, uint64 endBlock);

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
