// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LiquidityLauncher} from "../../src/LiquidityLauncher.sol";
import {ForwarderConfig} from "../../src/strategies/ForwarderStrategy.sol";

/// @notice Third-party stand-in that reenters the launcher to puppet the forwarder mid-call.
contract ReentrantForwarderTarget {
    LiquidityLauncher public immutable launcher;
    address public immutable forwarderStrategy;

    constructor(LiquidityLauncher _launcher, address _forwarderStrategy) {
        launcher = _launcher;
        forwarderStrategy = _forwarderStrategy;
    }

    /// @dev Invoked by `ForwarderStrategy._call`; immediately hands off to the launcher again.
    function triggerReentry() external payable {
        launcher.distributeWithNative(
            forwarderStrategy,
            abi.encode(ForwarderConfig({target: address(this), recipient: address(0), data: ""})),
            bytes32(0),
            0
        );
    }

    receive() external payable {}
}
