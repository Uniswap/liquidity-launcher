// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {MockDistributionContract} from "./MockDistributionContract.sol";

/// @notice Strategy that pulls strictly less than the approved amount, leaving unconsumed allowance
/// against the launcher. Used to verify the launcher's allowance-exhaustion guard.
contract MockUnderClaimingStrategy is IDistributionStrategy {
    using SafeERC20 for IERC20;

    uint256 public immutable shortfall;

    constructor(uint256 _shortfall) {
        shortfall = _shortfall;
    }

    function initializeDistribution(address token, uint256 amount, bytes calldata, bytes32) external override {
        address distributionContract = address(new MockDistributionContract());
        // Pull less than the launcher pre-approved. The unconsumed allowance against this strategy
        // is what the guard in distributeToken rejects.
        IERC20(token).safeTransferFrom(msg.sender, distributionContract, amount - shortfall);
    }
}
