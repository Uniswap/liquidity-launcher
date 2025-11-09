// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVirtualERC20} from "../../src/interfaces/external/IVirtualERC20.sol";
import {ERC20} from "@openzeppelin-latest/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin-latest/contracts/token/ERC20/IERC20.sol";

/// @title MockVirtualERC20
/// @notice Simple mock erc20 which holds the total supply of the underlying token and only
///         transfers the underlying token to the position manager
contract MockVirtualERC20 is IVirtualERC20, ERC20 {
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address public immutable UNDERLYING_TOKEN_ADDRESS;

    constructor(address _underlyingTokenAddress, uint128 initialSupply, address recipient)
        ERC20("Test Virtual Token", "VTEST")
    {
        UNDERLYING_TOKEN_ADDRESS = _underlyingTokenAddress;
        // mint initial supply of virtual token to the recipient
        _mint(recipient, initialSupply);
    }

    // transfers the underlying token to the recipient
    function transfer(address to, uint256 amount) public override(IVirtualERC20, ERC20) returns (bool) {
        // only time to transfer underlying token is to position manager
        bool success = super.transfer(to, amount);
        if (to == POSITION_MANAGER) {
            return IERC20(UNDERLYING_TOKEN_ADDRESS).transfer(to, amount);
        }
        return success;
    }
}
