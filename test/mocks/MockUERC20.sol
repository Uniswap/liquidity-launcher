// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice MockERC20 exposing the UERC20 `creator()` surface.
contract MockUERC20 is MockERC20 {
    address public immutable creator;

    constructor(string memory name, string memory symbol, uint256 initialSupply, address recipient, address _creator)
        MockERC20(name, symbol, initialSupply, recipient)
    {
        creator = _creator;
    }
}

/// @notice Token whose `creator()` reverts, for fallback-path testing.
contract MockRevertingCreatorToken is MockERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply, address recipient)
        MockERC20(name, symbol, initialSupply, recipient)
    {}

    function creator() external pure returns (address) {
        revert("no creator");
    }
}

/// @notice Mock of a launcher-created UERC20: `creator()` reports the launcher and the original
///         creator exists only as the graffiti hash, mirroring the canonical createToken flow.
contract MockLauncherUERC20 is MockERC20 {
    address public immutable creator;
    bytes32 public immutable graffiti;

    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply,
        address recipient,
        address _launcher,
        address _originalCreator
    ) MockERC20(name, symbol, initialSupply, recipient) {
        creator = _launcher;
        graffiti = keccak256(abi.encode(_originalCreator));
    }
}
