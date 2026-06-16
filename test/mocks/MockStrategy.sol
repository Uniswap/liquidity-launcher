// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IDistributor} from "../../src/interfaces/IDistributor.sol";
import {MockDistributor} from "./MockDistributor.sol";

contract MockStrategy is IStrategy {
    using SafeERC20 for IERC20;

    IDistributor public distributor;

    function initializeDistribution(address token, uint256 amount, bytes calldata, bytes32) external override {
        distributor = IDistributor(address(new MockDistributor()));
        IERC20(token).safeTransferFrom(msg.sender, address(distributor), amount);
    }
}
