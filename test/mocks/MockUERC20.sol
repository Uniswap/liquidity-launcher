// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An ERC20 that exposes a settable UERC20-style graffiti.
contract MockUERC20 is ERC20 {
    bytes32 public graffiti;

    constructor(string memory name, string memory symbol, uint256 initialSupply, address recipient, address creator)
        ERC20(name, symbol)
    {
        graffiti = keccak256(abi.encode(creator));
        _mint(recipient, initialSupply);
    }

    function setCreator(address creator) external {
        graffiti = keccak256(abi.encode(creator));
    }
}
