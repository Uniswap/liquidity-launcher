// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "./IERC20.sol";

interface IVirtualERC20 is IERC20 {
    function UNDERLYING_TOKEN_ADDRESS() external view returns (address);
}