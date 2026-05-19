// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {MockDistributionContract} from "./MockDistributionContract.sol";

contract MockDistributionStrategy is IDistributionStrategy {
    using SafeERC20 for IERC20;

    function initializeDistribution(address token, uint256 amount, bytes calldata, bytes32)
        external
        override
        returns (IDistributionContract distributionContract)
    {
        distributionContract = IDistributionContract(address(new MockDistributionContract()));
        IERC20(token).safeTransferFrom(msg.sender, address(distributionContract), amount);
    }
}
