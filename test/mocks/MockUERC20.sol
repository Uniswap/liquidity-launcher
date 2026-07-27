// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An ERC20 exposing a UERC20-style graffiti recording its creator.
contract MockUERC20 is ERC20 {
    bytes32 public immutable graffiti;

    constructor(string memory name, string memory symbol, uint256 initialSupply, address recipient, address creator)
        ERC20(name, symbol)
    {
        graffiti = keccak256(abi.encode(creator));
        _mint(recipient, initialSupply);
    }
}
