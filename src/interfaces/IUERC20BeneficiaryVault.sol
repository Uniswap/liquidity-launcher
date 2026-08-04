// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IBeneficiaryVault} from "./IBeneficiaryVault.sol";

/// @title IUERC20BeneficiaryVault
/// @notice A BeneficiaryVault that also lets the creator of a launcher-created UERC20 register and
///         claim the fee shares of unregistered positions paired with it.
interface IUERC20BeneficiaryVault is IBeneficiaryVault {
    /// @notice Thrown when the caller is not authorized for the position.
    /// @param tokenId The position token ID.
    /// @param caller The unauthorized caller.
    error NotAuthorized(uint256 tokenId, address caller);

    /// @notice Mints the beneficiary NFT to `beneficiary` when the caller matches the pair's UERC20 graffiti.
    /// @param tokenId The position token ID.
    /// @param beneficiary The receiver of the beneficiary NFT.
    function register(uint256 tokenId, address beneficiary) external;
}
