// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniversalRouter} from "../../src/interfaces/external/IUniversalRouter.sol";
import {LiquidityLauncher} from "../../src/LiquidityLauncher.sol";
import {UniversalRouterConfig} from "../../src/strategies/UniversalRouterStrategy.sol";

/// @notice Router stand-in that reenters the launcher to puppet the strategy mid-route.
contract ReentrantRouter is IUniversalRouter {
    LiquidityLauncher public immutable launcher;
    address public immutable strategy;

    constructor(LiquidityLauncher _launcher, address _strategy) {
        launcher = _launcher;
        strategy = _strategy;
    }

    /// @inheritdoc IUniversalRouter
    /// @dev Ignores the route and hands straight back to the launcher.
    function execute(bytes calldata, bytes[] calldata, uint256) external payable override {
        launcher.distributeWithNative(
            strategy,
            abi.encode(
                UniversalRouterConfig({
                    router: IUniversalRouter(address(this)),
                    recipient: address(0),
                    route: abi.encode(bytes(""), new bytes[](0), block.timestamp)
                })
            ),
            bytes32(0),
            0
        );
    }

    receive() external payable {}
}
