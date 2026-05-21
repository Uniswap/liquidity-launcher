// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";

contract MockDistributionStrategyAndContract is IDistributionStrategy, IDistributionContract {
    using SafeERC20 for IERC20;

    function initializeDistribution(address token, uint256 amount, bytes calldata, bytes32) external override {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function onTokensReceived() external {}
}
