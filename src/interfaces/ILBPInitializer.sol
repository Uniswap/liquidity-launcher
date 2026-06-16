// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IDistributor} from "./IDistributor.sol";

/// @dev The interface id of the ILBPInitializer interface
/// @dev Per ERC165, the interface selector is the XOR of the selectors of the interfaces implemented by the contract
bytes4 constant ILBP_INITIALIZER_INTERFACE_ID = type(ILBPInitializer).interfaceId;

/// @notice General parameters for initializing an LBP strategy
struct LBPInitializationParams {
    uint256 initialPriceX96; // the price discovered by the contract
    uint256 tokensSold; // the number of tokens sold by the contract
    uint256 currencyRaised; // the amount of currency raised by the contract
}

/// @title ILBPInitializer
/// @notice Generic interface for contracts used for initializing an LBP strategy
interface ILBPInitializer is IDistributor, IERC165 {
    /// @notice Returns the LBP initialization parameters as determined by the implementing contract
    /// @dev The implementing contract MUST ensure that these values are correct at the time of calling
    function lbpInitializationParams() external view returns (LBPInitializationParams memory);

    /// @notice Sweeps the raised currency from the initializer. Must NOT revert.
    /// @dev The initializer must ensure this can only be called by the currency recipient directly.
    /// @dev MUST transfer exactly `currencyRaised` (from {lbpInitializationParams}) to the funds recipient.
    ///      `tryMigrate` enforces `received == currencyRaised` and reverts if unequal. Any surplus held by the
    ///      initializer must be left behind, not swept here.
    function sweepCurrency() external;

    /// @notice Sweeps the unsold tokens from the initializer. Must NOT revert.
    /// @dev The initializer must ensure this can only be called by the tokens recipient directly
    function sweepUnsoldTokens() external;

    /// @notice Returns the token used by the initializer
    function token() external view returns (address);
    /// @notice Returns the currency used by the initializer
    function currency() external view returns (address);
    /// @notice Returns the total supply of the token used by the initializer
    function totalSupply() external view returns (uint128);
    /// @notice Returns the address which will receive the unsold tokens
    function tokensRecipient() external view returns (address);
    /// @notice Returns the address which will receive the raised currency
    function fundsRecipient() external view returns (address);
    /// @notice Returns the start block of the initializer
    function startBlock() external view returns (uint64);
    /// @notice Returns the end block of the initializer
    function endBlock() external view returns (uint64);
}
