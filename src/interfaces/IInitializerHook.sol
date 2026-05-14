// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IInitializerHook
/// @notice ERC165 interface for hooks that gate pool initialization to an address
interface IInitializerHook is IERC165 {
    /// @notice The address authorized to initialize pools using this hook
    function authorized() external view returns (address);
}
