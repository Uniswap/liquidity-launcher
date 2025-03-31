// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {UniswapERC20} from "uniswapERC20-factory/UniswapERC20.sol";
import {IUniswapERC20Factory} from "uniswapERC20-factory/interfaces/IUniswapERC20Factory.sol";
import {UniswapERC20Factory} from "uniswapERC20-factory/UniswapERC20Factory.sol";
import {Bootstrapper} from "../src/Bootstrapper.sol";
import {Helpers} from "./utils/Helpers.sol";

contract BootstrapperTest is Helpers {
    Bootstrapper public bootstrapper;
    IUniswapERC20Factory public tokenFactory;
    UniswapERC20 public token;

    function setUp() public {
        tokenFactory = new UniswapERC20Factory();
    }

    function test_deploy() public {
        (bootstrapper, token) = _deployTokenAndBootstrapper(tokenFactory);
    }
}
