// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";

/// @notice Adversarial leftoverRecipient that reenters `strategy.migrate(initializer)` from its
/// receive() when it gets ETH during migrate's leftover-currency-transfer leg.
contract MockReentrantMigrateRecipient {
    ILBPStrategy public immutable strategy;

    ILBPInitializer public initializer;
    bool public reentered;
    bytes public capturedRevertData;

    constructor(ILBPStrategy _strategy) {
        strategy = _strategy;
    }

    function setInitializer(ILBPInitializer _initializer) external {
        initializer = _initializer;
    }

    receive() external payable {
        if (reentered || address(initializer) == address(0)) {
            return;
        }
        reentered = true;
        // Low-level call so we can capture the inner revert reason without bubbling it up to the
        // outer transfer (which would otherwise propagate and revert the entire outer call).
        (bool ok, bytes memory reason) = address(strategy).call(abi.encodeCall(strategy.migrate, (initializer)));
        if (!ok) {
            capturedRevertData = reason;
        }
    }
}
