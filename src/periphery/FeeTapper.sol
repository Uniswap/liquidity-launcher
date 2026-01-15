// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Tap, Keg, IFeeTapper} from "../interfaces/periphery/IFeeTapper.sol";

/// @title FeeTapper
/// @notice Singleton contract which handles the streaming of incoming protocol fees to TokenJar
contract FeeTapper is IFeeTapper, Ownable {
    using CurrencyLibrary for Currency;

    address public immutable tokenJar;

    /// @notice Mapping of currencies to Taps
    mapping(Currency => Tap) private $_taps;
    /// @notice Linked list of kegs. Taps manage the head and tail of their respective kegs.
    mapping(uint32 => Keg) private $_kegs;
    /// @notice The id of the next keg to be created
    uint32 public nextId;

    /// @notice Basis points denominator
    uint24 public constant BPS = 10_000;
    /// @notice The release rate for accrued protocol fees in basis points per block.
    ///         For example, at 10 basis points the full amount is released over 1_000 blocks.
    /// @dev    This helps smooth out the release of fees which is useful for integrating with TokenJar fee exchangers.
    uint24 public perBlockReleaseRate = 10;

    /// @notice The maximum supported balance to prevent overflowing a uint128
    uint128 public constant MAX_BALANCE = type(uint128).max / BPS;

    constructor(address _tokenJar, address _owner) Ownable(_owner) {
        tokenJar = _tokenJar;
    }

    /// @notice Gets the tap for the given currency, if active
    function taps(Currency currency) external view returns (Tap memory) {
        return $_taps[currency];
    }

    /// @notice Gets the keg for the given id
    function kegs(uint32 id) external view returns (Keg memory) {
        return $_kegs[id];
    }

    /// @inheritdoc IFeeTapper
    function setReleaseRate(uint24 _perBlockReleaseRate) external onlyOwner {
        if (_perBlockReleaseRate == 0 || _perBlockReleaseRate > BPS) revert ReleaseRateOutOfBounds();
        if (BPS % _perBlockReleaseRate != 0) revert InvalidReleaseRate();
        perBlockReleaseRate = _perBlockReleaseRate;
        emit ReleaseRateSet(_perBlockReleaseRate);
    }

    /// @inheritdoc IFeeTapper
    function sync(Currency currency) external {
        // Release any accrued protocol fees
        _release(currency);

        Tap storage $tap = $_taps[currency];
        // Silently truncates any received balances over uint128.max
        uint128 balance = uint128(currency.balanceOfSelf());
        uint128 oldBalance = $tap.balance;
        // noop if there hasn't been a change in balance
        if (balance == oldBalance) return;

        unchecked {
            nextId++;
        }
        uint32 next = nextId;

        uint48 endBlock = uint48(block.number + BPS / perBlockReleaseRate);
        uint128 amount = balance - oldBalance;
        // Revert if the amount added to the tap would eventually overflow a uint128
        if (amount > MAX_BALANCE) revert AmountTooLarge();
        uint128 perBlockReleaseAmount = amount * perBlockReleaseRate;

        Keg storage $keg = $_kegs[next];
        $keg.perBlockReleaseAmount += perBlockReleaseAmount;
        $keg.lastReleaseBlock = uint48(block.number);
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

        emit Deposited(next, Currency.unwrap(currency), amount, endBlock);
        emit Synced(Currency.unwrap(currency), balance);
    }

    /// @inheritdoc IFeeTapper
    function release(Currency currency) external returns (uint128) {
        return _process(currency, _release(currency));
    }

    /// @inheritdoc IFeeTapper
    function release(Currency currency, uint32 id) external returns (uint128) {
        // Require id to exist in Tap
        uint32 next = $_taps[currency].head;
        while (next != 0) {
            if (next == id) {
                break;
            }
            next = $_kegs[next].next;
        }
        if (next == 0) revert KegNotFound(id);
        return _process(currency, _releaseKeg($_kegs[id], id));
    }

    /// @notice Releases a single keg for a given currency
    /// @param id The id of the keg to release
    function _releaseKeg(Keg memory keg, uint32 id) internal returns (uint128 releasedAmount) {
        releasedAmount = uint128(
            keg.perBlockReleaseAmount * (FixedPointMathLib.min(block.number, keg.endBlock) - keg.lastReleaseBlock)
        );
        if (keg.lastReleaseBlock != block.number) {
            $_kegs[id].lastReleaseBlock = uint48(block.number);
        }
        return releasedAmount;
    }

    /// @notice Releases all kegs for a given currency
    function _release(Currency currency) internal returns (uint128 releasedAmount) {
        Tap storage $tap = $_taps[currency];
        if ($tap.balance == 0) {
            return 0;
        }

        uint32 next = $tap.head;
        uint32 newHead;
        // Itereate through all kegs. This can be very costly if there are lot of kegs.
        while (next != 0) {
            Keg memory keg = $_kegs[next];
            uint32 curr = next;
            releasedAmount += _releaseKeg(keg, curr);
            next = keg.next;
            if (keg.endBlock <= block.number) {
                // Update the head (since this keg is fully released)
                newHead = next;
                // Delete the old keg
                delete $_kegs[curr];
                // If we have iterated through all of the kegs reset the head/tail to 0
                if (next == 0) {
                    $tap.head = 0;
                    $tap.tail = 0;
                    break;
                }
            }
        }
        // Update the head if it needed
        if (newHead != 0) {
            $tap.head = newHead;
        }
        return releasedAmount;
    }

    /// @notice Transfers the released amount to the token jar
    function _process(Currency _currency, uint128 _releasedAmount) internal returns (uint128) {
        // Because we deferred dividing by BPS when storing the perBlockReleaseAmount, we need to divide now
        uint128 toRelease = _releasedAmount / BPS;
        // Update the tap balance
        $_taps[_currency].balance -= toRelease;

        if (toRelease > 0) {
            _currency.transfer(tokenJar, toRelease);
            emit Released(Currency.unwrap(_currency), toRelease);
        }
        return toRelease;
    }

    /// @notice Receives ETH
    receive() external payable {}
}
