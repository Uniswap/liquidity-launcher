// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Tap, Keg, IFeeTapper} from "../interfaces/periphery/IFeeTapper.sol";
import {console2} from "forge-std/console2.sol";

/// @title FeeTapper
/// @notice Singleton contract which handles the streaming of incoming protocol fees to TokenJar
contract FeeTapper is IFeeTapper, Ownable {
    using CurrencyLibrary for Currency;

    address public immutable tokenJar;

    /// @notice Mapping of currencies to Taps
    mapping(Currency => Tap) private $_taps;
    /// @notice Linked list of kegs. Taps manage the head and tail of their respective kegs.
    mapping(uint64 => Keg) private $_kegs;
    /// @notice The id of the next keg to be created
    uint64 public nextId;

    /// @notice Basis points denominator
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
        uint128 oldBalance = $tap.balance;
        // noop if there hasn't been a change in balance
        if (balance == oldBalance) return;

        unchecked {
            nextId++;
        }
        uint64 next = nextId;

        uint64 endBlock = uint64(block.number + BPS / perBlockReleaseRate);
        Keg storage $keg = $_kegs[next];
        uint128 perBlockReleaseAmount = (balance - oldBalance) * perBlockReleaseRate;
        $keg.perBlockReleaseAmount += perBlockReleaseAmount;
        $keg.lastReleaseBlock = uint64(block.number);
        $keg.endBlock = endBlock;
        if ($tap.head == 0) {
            $tap.head = next;
            $tap.tail = next;
        } else {
            $_kegs[$tap.tail].next = next;
            $keg.next = 0;
            $tap.tail = next;
        }
        $tap.balance = balance;

        emit Deposited(next, Currency.unwrap(currency), perBlockReleaseAmount, endBlock);
        emit Synced(Currency.unwrap(currency), balance);
    }

    /// @notice Releases all accumulated protocol fees for a given currency to the protocol fee recipient
    function release(Currency currency) external returns (uint128) {
        return _process(currency, _release(currency));
    }

    /// @notice Internal release logic for a given keg
    function _release(Currency currency, uint64 id) internal returns (uint128 releasedAmount) {
        Keg memory keg = $_kegs[id];
        if (keg.endBlock <= block.number) {
            releasedAmount = uint128(keg.perBlockReleaseAmount * (keg.endBlock - keg.lastReleaseBlock));
            // Update the head (since this keg is fully released)
            $_taps[currency].head = keg.next;
            // Delete the old keg
            delete $_kegs[id];
        } else {
            releasedAmount = uint128(keg.perBlockReleaseAmount * (block.number - keg.lastReleaseBlock));
            $_kegs[id].lastReleaseBlock = uint64(block.number);
        }
        return releasedAmount;
    }

    /// @notice Releases all kegs for a given currency
    function _release(Currency currency) internal returns (uint128 releasedAmount) {
        Tap storage $tap = $_taps[currency];
        if ($tap.balance == 0) {
            return 0;
        }

        uint64 next = $tap.head;
        uint64 newHead;
        // Itereate through all kegs
        while (next != 0) {
            Keg memory keg = $_kegs[next];
            uint64 curr = next;
            next = keg.next;
            if (keg.endBlock <= block.number) {
                releasedAmount += uint128(keg.perBlockReleaseAmount * (keg.endBlock - keg.lastReleaseBlock));
                // Update the head (since this keg is fully released)
                newHead = keg.next;
                // Delete the old keg
                delete $_kegs[curr];
            } else {
                releasedAmount += uint128(keg.perBlockReleaseAmount * (block.number - keg.lastReleaseBlock));
                $_kegs[curr].lastReleaseBlock = uint64(block.number);
            }
        }
        // Update the head if it needed
        if(newHead != 0) {
            $_taps[currency].head = newHead;
        }
        return releasedAmount;
    }

    /// @notice Processes the release of an amount of fees to the protocol fee recipient
    function _process(Currency _currency, uint128 _toRelease) internal returns (uint128) {
        // Because we deferred dividing by BPS when storing the perBlockReleaseAmount, we need to divide now
        _toRelease = _toRelease / BPS;
        // Update the tap balance
        $_taps[_currency].balance -= _toRelease;

        if (_toRelease > 0) {
            _currency.transfer(tokenJar, _toRelease);
            emit Released(Currency.unwrap(_currency), _toRelease);
        }
        return _toRelease;
    }

    /// @notice Receives ETH
    receive() external payable {}
}
