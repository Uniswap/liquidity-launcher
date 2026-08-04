// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {INativeStrategy} from "../interfaces/INativeStrategy.sol";
import {IUniversalRouter} from "../interfaces/external/IUniversalRouter.sol";

/// @notice The route to run, carried in `configData`.
/// @param router The Universal Router to forward the route to.
/// @param recipient Receiver of any distributed token the route did not use.
/// @param data ABI-encoded `IUniversalRouter.execute(commands, inputs, deadline)` calldata.
struct UniversalRouterConfig {
    IUniversalRouter router;
    address recipient;
    bytes data;
}

/// @title UniversalRouterStrategy
/// @notice Forwards a caller-supplied Universal Router route, so a launch and a buy fit in one transaction.
/// @dev Funded either by native forwarded to `initializeWithNative` or by an allowance on the distributed
///      token in `initializeDistribution`. Holds no balance between calls: there is no `receive` and both
///      entry points are launcher-only. The route MUST name its own recipient for everything it produces,
///      including unspent native, which this strategy cannot receive back.
/// @custom:security-contact security@uniswap.org
contract UniversalRouterStrategy is IStrategy, INativeStrategy {
    using SafeERC20 for IERC20;

    /// @notice The only address allowed to run this strategy
    address public immutable launcher;

    /// @notice Thrown when anything but the launcher runs this strategy
    error OnlyLauncher();
    /// @notice Thrown when `data` is not a call to `IUniversalRouter.execute`
    error InvalidCall();

    constructor(address _launcher) {
        launcher = _launcher;
    }

    /// @inheritdoc INativeStrategy
    /// @dev Spends the forwarded native; the route sweeps any remainder itself.
    function initializeWithNative(bytes calldata configData, bytes32) external payable override {
        if (msg.sender != launcher) revert OnlyLauncher();
        UniversalRouterConfig memory config = abi.decode(configData, (UniversalRouterConfig));
        _call(config.router, config.data, msg.value);
        emit DistributionInitialized(address(this), address(0), msg.value);
    }

    /// @inheritdoc IStrategy
    /// @dev Pays `amount` of `token` to the router and returns any unused amount to `recipient`.
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32)
        external
        override
    {
        if (msg.sender != launcher) revert OnlyLauncher();
        UniversalRouterConfig memory config = abi.decode(configData, (UniversalRouterConfig));
        if (amount != 0) IERC20(token).safeTransferFrom(launcher, address(config.router), amount);

        _call(config.router, config.data, 0);

        uint256 unused = IERC20(token).balanceOf(address(this));
        if (unused != 0) IERC20(token).safeTransfer(config.recipient, unused);

        emit DistributionInitialized(address(this), token, amount);
    }

    /// @notice Forwards `data` to the router and bubbles up any revert
    function _call(IUniversalRouter router, bytes memory data, uint256 value) private {
        if (data.length < 4 || bytes4(data) != IUniversalRouter.execute.selector) revert InvalidCall();
        (bool success, bytes memory returnData) = address(router).call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
