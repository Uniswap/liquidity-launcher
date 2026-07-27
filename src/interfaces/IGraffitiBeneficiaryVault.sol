// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IBeneficiaryVault} from "./IBeneficiaryVault.sol";

/// @title IGraffitiBeneficiaryVault
/// @notice A BeneficiaryVault that also lets the creator of a launcher-created token claim the fee
///         shares of unregistered positions paired with it.
interface IGraffitiBeneficiaryVault is IBeneficiaryVault {
    /// @notice Thrown when an unregistered position pairs a launcher-created token and the caller is
    ///         not its creator.
    /// @param tokenId The position token ID.
    /// @param caller The unauthorized caller.
    error NotTokenCreator(uint256 tokenId, address caller);
}
