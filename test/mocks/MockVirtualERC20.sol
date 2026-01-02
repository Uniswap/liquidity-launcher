// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "./MockERC20.sol";
import {IVirtualERC20} from "src/interfaces/external/IVirtualERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockVirtualERC20 is MockERC20, IVirtualERC20 {
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address public immutable UNDERLYING_TOKEN_ADDRESS;

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        address _underlyingTokenAddress
    ) MockERC20(name, symbol, initialSupply, recipient) {
        UNDERLYING_TOKEN_ADDRESS = _underlyingTokenAddress;
    }

    function transfer(address to, uint256 amount) public override(ERC20, IVirtualERC20) returns (bool) {
        // only time to transfer underlying token is to position manager
        bool success = super.transfer(to, amount);
        if (to == POSITION_MANAGER) {
            return IERC20(UNDERLYING_TOKEN_ADDRESS).transfer(to, amount);
        }
        return success;
    }
}
