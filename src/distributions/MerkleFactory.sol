// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {IMerkleFactory} from "../interfaces/IMerkleFactory.sol";
import {MerkleClaim} from "./MerkleClaim.sol";

contract MerkleClaimFactory is IMerkleFactory {
    using SafeERC20 for IERC20;

    /// @notice Deploys a new MerkleClaim and funds it with `amount` tokens.
    /// @param token The ERC-20 token to distribute.
    /// @param amount Amount of `token` intended for distribution.
    /// @param configData ABI-encoded (merkleRoot, owner, deadline) where deadline is optional (0 = no deadline).
    /// @return distributionContract The freshly deployed MerkleClaim.
    function initializeDistribution(
        address token,
        uint256 amount,
        bytes calldata configData
    ) external override returns (IDistributionContract distributionContract) {
        if (token == address(0)) revert ZeroAddress();
        if (configData.length != 96) revert InvalidConfig(); // 32 bytes for merkleRoot + 20 bytes for owner + 32 bytes for deadline

        // Decode the merkle root, owner, and deadline from configData
        (bytes32 merkleRoot, address owner, uint256 deadline) = abi.decode(configData, (bytes32, address, uint256));

        return IDistributionContract(new MerkleClaim(token, merkleRoot, owner, deadline));
    }
}
