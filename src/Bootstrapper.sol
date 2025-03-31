// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UniswapERC20} from "uniswapERC20-factory/UniswapERC20.sol";

contract Bootstrapper {
    UniswapERC20 immutable token;

    constructor(UniswapERC20 _token) {
        token = _token;
    }
}
