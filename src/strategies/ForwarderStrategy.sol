// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {INativeStrategy} from "../interfaces/INativeStrategy.sol";

/// @notice Configuration for an arbitrary external call carried in `configData`.
/// @param target The contract to call.
/// @param recipient Receiver of any distributed token the call did not use.
/// @param data Calldata forwarded to `target`.
struct ForwarderConfig {
    address target;
    address recipient;
    bytes data;
}

/// @title ForwarderStrategy
/// @notice Forwards a caller-supplied call to any target alongside a token or native distribution.
/// @dev Use this strategy when a launch needs to perform arbitrary external calls in the same
///      transaction as a distribution. Supports native payment via `initializeWithNative`
///      and ERC-20 funding via `initializeDistribution`.
/// @dev This contract MUST NOT hold balance or approvals between calls. Any permissions given to
///      this contract can be exploited by any caller.
/// @custom:security-contact security@uniswap.org
contract ForwarderStrategy is IStrategy, INativeStrategy, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The only address allowed to run this strategy
    address public immutable launcher;

    /// @notice Thrown when anything but the launcher runs this strategy
    error OnlyLauncher();

    constructor(address _launcher) {
        launcher = _launcher;
    }

    /// @inheritdoc INativeStrategy
    /// @dev Spends the forwarded native; the call sweeps any remainder itself.
    function initializeWithNative(bytes calldata configData, bytes32) external payable override nonReentrant {
        if (msg.sender != launcher) revert OnlyLauncher();
        ForwarderConfig memory config = abi.decode(configData, (ForwarderConfig));
        _call(config.target, config.data, msg.value);
        emit DistributionInitialized(address(this), address(0), msg.value);
    }

    /// @inheritdoc IStrategy
    /// @dev Pays `amount` of `token` to the target and returns any unused amount to `recipient`.
    function initializeDistribution(address token, uint256 amount, bytes calldata configData, bytes32)
        external
        override
        nonReentrant
    {
        if (msg.sender != launcher) revert OnlyLauncher();
        ForwarderConfig memory config = abi.decode(configData, (ForwarderConfig));
        if (amount != 0) IERC20(token).safeTransferFrom(launcher, config.target, amount);

        _call(config.target, config.data, 0);

        uint256 unused = IERC20(token).balanceOf(address(this));
        if (unused != 0) IERC20(token).safeTransfer(config.recipient, unused);

        emit DistributionInitialized(address(this), token, amount);
    }

    /// @notice Forwards `data` to `target` and bubbles up any revert
    function _call(address target, bytes memory data, uint256 value) private {
        (bool success, bytes memory returnData) = target.call{value: value}(data);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}
