// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVirtualERC20 is IERC20 {
    function UNDERLYING_TOKEN_ADDRESS() external view returns (address);
    function transfer(address to, uint256 amount) external returns (bool);
}