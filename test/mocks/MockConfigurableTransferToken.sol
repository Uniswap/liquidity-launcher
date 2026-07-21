// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @notice Token whose `transfer` misbehaves only when called by a configured caller, to exercise the
///         FeeSplitter's gas-capped distribution transfers: burn a fixed amount of gas, burn the whole
///         budget, or return false. Scoping the misbehavior to one caller keeps the v4 take path
///         (PoolManager -> splitter) working so the collect reaches the distribution step.
contract MockConfigurableTransferToken is MockERC20 {
    /// @dev The only msg.sender for which transfers misbehave; zero disables all misbehavior.
    address public misbehaveWhenCalledBy;
    /// @dev Gas to waste per misbehaving transfer; type(uint256).max burns the entire forwarded budget.
    uint256 public wasteGas;
    bool public returnFalse;

    constructor(string memory name, string memory symbol, uint256 initialSupply, address recipient)
        MockERC20(name, symbol, initialSupply, recipient)
    {}

    function setMisbehavior(address caller, uint256 _wasteGas, bool _returnFalse) external {
        misbehaveWhenCalledBy = caller;
        wasteGas = _wasteGas;
        returnFalse = _returnFalse;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (msg.sender == misbehaveWhenCalledBy) {
            uint256 target = wasteGas;
            if (target == type(uint256).max) {
                while (true) {}
            } else if (target != 0) {
                uint256 start = gasleft();
                while (start - gasleft() < target) {}
            }
            if (returnFalse) return false;
        }
        return super.transfer(to, amount);
    }
}
