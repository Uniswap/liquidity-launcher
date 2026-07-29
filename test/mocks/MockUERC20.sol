// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice An ERC20 that exposes a UERC20-style graffiti, optionally made unreadable.
contract MockUERC20 is ERC20 {
    error GraffitiUnavailable();

    bytes32 internal _graffiti;
    bool internal _graffitiReverts;

    constructor(string memory name, string memory symbol, uint256 initialSupply, address recipient, address creator)
        ERC20(name, symbol)
    {
        _graffiti = keccak256(abi.encode(creator));
        _mint(recipient, initialSupply);
    }

    function graffiti() external view returns (bytes32) {
        if (_graffitiReverts) revert GraffitiUnavailable();
        return _graffiti;
    }

    function setGraffitiReverts(bool reverts) external {
        _graffitiReverts = reverts;
    }
}
