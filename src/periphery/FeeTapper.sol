// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Tap, IFeeTapper} from "../interfaces/periphery/IFeeTapper.sol";

/// @title FeeTapper
/// @notice Singleton contract which handles the streaming of incoming protocol fees to TokenJar
contract FeeTapper is IFeeTapper, Ownable {
    using CurrencyLibrary for Currency;

    address public immutable tokenJar;

    mapping(Currency => Tap) private $_taps;

    uint24 public constant BPS = 10_000;
    /// @notice The release rate for accrued protocol fees in basis points per block.
    ///         For example, at 10 basis points the full amount is released over 1_000 blocks.
    /// @dev    This helps smooth out the release of fees which is useful for integrating with TokenJar fee exchangers.
    uint24 public perBlockReleaseRate = 10;

    constructor(address _tokenJar, address _owner) Ownable(_owner) {
        tokenJar = _tokenJar;
    }

    /// @notice Gets the tap for the given currency, if active
    function taps(Currency currency) external view returns (Tap memory) {
        return $_taps[currency];
    }

    /// @notice Sets the release rate for accrued protocol fees in basis points per block
    /// @dev Only callable by the owner
    /// @param _perBlockReleaseRate The new release rate in basis points per block. Must be non zero and <= BPS
    function setReleaseRate(uint24 _perBlockReleaseRate) external onlyOwner {
        if (_perBlockReleaseRate == 0 || _perBlockReleaseRate > BPS) revert InvalidReleaseRate();
        perBlockReleaseRate = _perBlockReleaseRate;
        emit ReleaseRateSet(_perBlockReleaseRate);
    }

    /// @notice Syncs the fee tapper with received protocol fees. Callable by anyone
    /// @param currency The currency to sync
    function sync(Currency currency) external {
        // Release any accrued protocol fees
        _release(currency);

        Tap storage $tap = $_taps[currency];
        uint128 balance = uint128(currency.balanceOfSelf());
        // noop if there hasn't been a change in balance
        if (balance == $tap.balance) return;

        $tap.lastReleaseBlock = uint64(block.number);
        $tap.balance = balance;

        emit Synced(Currency.unwrap(currency), balance);
    }

    /// @notice Releases any accrued protocol fees to the protocol fee recipient
    /// @dev Callable by anyone to release any accrued protocol fees
    function release(Currency currency) external returns (uint192) {
        return _release(currency);
    }

    /// @notice Releases currency to the protocol fee recipient over time according to the release rate
    function _release(Currency currency) internal returns (uint192) {
        Tap storage $tap = $_taps[currency];
        if ($tap.balance == 0) {
            $tap.lastReleaseBlock = uint64(block.number);
            return 0;
        }
        uint256 elapsed = block.number - $tap.lastReleaseBlock;
        if (elapsed == 0) return 0;

        // Calculate the amount of protocol fees to release
        uint192 toRelease = uint192(FixedPointMathLib.fullMulDiv($tap.balance * perBlockReleaseRate, elapsed, BPS));
        if (toRelease > $tap.balance) toRelease = $tap.balance;

        $tap.balance -= toRelease;
        $tap.lastReleaseBlock = uint64(block.number);

        if (toRelease > 0) {
            currency.transfer(tokenJar, toRelease);
            emit Released(Currency.unwrap(currency), toRelease);
        }
        return toRelease;
    }

    /// @notice Receives ETH
    receive() external payable {}
}
