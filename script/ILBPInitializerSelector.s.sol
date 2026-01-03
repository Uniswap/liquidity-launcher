// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ILBPInitializer} from "../src/interfaces/ILBPInitializer.sol";

/// @dev https://eips.ethereum.org/EIPS/eip-165#specification
contract ILBPInitializerSelectorScript is Script {
    /// @notice Per ERC165, the interface selector is the XOR of the selectors of the interfaces implemented by the contract
    function selector() public pure returns (bytes4) {
        return ILBPInitializer.lbpInitializationParams.selector ^ ILBPInitializer.token.selector
            ^ ILBPInitializer.currency.selector ^ ILBPInitializer.totalSupply.selector
            ^ ILBPInitializer.tokensRecipient.selector ^ ILBPInitializer.fundsRecipient.selector
            ^ ILBPInitializer.startBlock.selector ^ ILBPInitializer.endBlock.selector;
    }

    function run() public {
        console.logBytes4(selector());
    }
}
