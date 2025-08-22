// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUERC20Factory} from "../interfaces/IUERC20Factory.sol";
import {BaseUERC20} from "./BaseUERC20.sol";

/// @title UERC20
/// @notice ERC20 token contract
contract UERC20 is BaseUERC20 {
    constructor() {
        IUERC20Factory.Parameters memory params = IUERC20Factory(msg.sender).getParameters();

        _name = params.name;
        _nameHash = keccak256(bytes(_name));
        _symbol = params.symbol;
        _decimals = params.decimals;
        creator = params.creator;
        graffiti = params.graffiti;
        metadata = params.metadata;

        _mint(params.recipient, params.totalSupply);
    }
}
