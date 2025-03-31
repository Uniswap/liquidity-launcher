// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {UniswapERC20} from "uniswapERC20-factory/UniswapERC20.sol";
import {IUniswapERC20Factory} from "uniswapERC20-factory/interfaces/IUniswapERC20Factory.sol";
import {UniswapERC20Metadata} from "uniswapERC20-factory/libraries/UniswapERC20Metadata.sol";
import {Bootstrapper} from "../../src/Bootstrapper.sol";
import {Test} from "forge-std/Test.sol";

contract Helpers is Test {
    function _deployTokenAndBootstrapper(IUniswapERC20Factory tokenFactory)
        internal
        returns (Bootstrapper bootstrapper, UniswapERC20 token)
    {
        token = tokenFactory.create(
            "TestToken",
            "TEST",
            18,
            block.chainid,
            UniswapERC20Metadata({creator: address(this), description: "", website: "", image: ""}),
            address(this),
            10_000e18
        );

        bootstrapper = new Bootstrapper(token);

        token.transfer(address(bootstrapper), 10_000e18);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(bootstrapper)), 10_000e18);
    }
}
