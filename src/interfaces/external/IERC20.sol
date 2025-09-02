// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Minimal ERC20 interface
interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
}
