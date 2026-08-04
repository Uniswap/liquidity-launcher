// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {INativeStrategy} from "../interfaces/INativeStrategy.sol";
import {IUniversalRouter} from "../interfaces/external/IUniversalRouter.sol";

/// @notice The route to run, carried in `configData`.
/// @param router The Universal Router to run the route on, so one deployment serves every version.
/// @param recipient Receiver of any distributed token the route did not use.
/// @param route `abi.encode(bytes commands, bytes[] inputs, uint256 deadline)` for `IUniversalRouter.execute`.
struct UniversalRouterConfig {
    IUniversalRouter router;
    address recipient;
    bytes route;
}

/// @title UniversalRouterStrategy
/// @notice Runs a caller-supplied Universal Router route, so a launch and a buy fit in one transaction.
/// @dev Funded either by native forwarded to `initializeWithNative` or by an allowance on the distributed
///      token in `initializeDistribution`. `execute` is the only call this strategy can make, and it holds no
///      balance between calls: there is no `receive` and both entry points are launcher-only.
///      The route MUST name its own recipient for everything it produces, including unspent native, which
///      this strategy cannot receive back.
/// @custom:security-contact security@uniswap.org
contract UniversalRouterStrategy is IStrategy, INativeStrategy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The only address allowed to run this strategy
    address public immutable launcher;

    /// @notice Thrown when anything but the launcher runs this strategy
    error OnlyLauncher();

    constructor(address _launcher) {
        launcher = _launcher;
    }

    /// @inheritdoc INativeStrategy
    /// @dev Spends the forwarded native; the route sweeps any remainder itself.
    function initializeWithNative(bytes calldata configData, bytes32) external payable override nonReentrant {
        if (msg.sender != launcher) revert OnlyLauncher();
        UniversalRouterConfig memory config = abi.decode(configData, (UniversalRouterConfig));

        // No `DistributionInitialized`: nothing is distributed here, and the launcher emits
        // `NativeDistributed` for this path.
        _execute(config.router, config.route, msg.value);
    }

    /// @inheritdoc IStrategy
    /// @dev Pays `amount` of `token` to the router and returns anything the route sent back to `recipient`.
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32)
        external
        override
        nonReentrant
    {
        if (msg.sender != launcher) revert OnlyLauncher();
        UniversalRouterConfig memory config = abi.decode(configData, (UniversalRouterConfig));
        if (amount != 0) IERC20(token).safeTransferFrom(launcher, address(config.router), amount);

        _execute(config.router, config.route, 0);

        uint256 unused = IERC20(token).balanceOf(address(this));
        if (unused != 0) IERC20(token).safeTransfer(config.recipient, unused);

        emit DistributionInitialized(address(this), token, amount);
    }

    /// @notice Decodes `route` and runs it on `router`
    function _execute(IUniversalRouter router, bytes memory route, uint256 value) private {
        (bytes memory commands, bytes[] memory inputs, uint256 deadline) = abi.decode(route, (bytes, bytes[], uint256));
        router.execute{value: value}(commands, inputs, deadline);
    }
}
