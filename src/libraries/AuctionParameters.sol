// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

library AuctionParameters {
    bytes32 internal constant AUCTION_PARAMETERS_SLOT =
        0x2a86bfecab7c1dc1a00b694d14a5a3c91a3ce748c12f853f875c4c7b4b254eb6;

    function setAuctionParameters(bytes memory data) internal {
        assembly {
            let length := mload(data)
            tstore(AUCTION_PARAMETERS_SLOT, length) // Store length in first slot

            let slots := div(add(length, 31), 32) // Calculate needed slots
            for { let i := 0 } lt(i, slots) { i := add(i, 1) } {
                let offset := add(data, add(32, mul(i, 32)))
                tstore(add(AUCTION_PARAMETERS_SLOT, add(i, 1)), mload(offset))
            }
        }
    }
}
