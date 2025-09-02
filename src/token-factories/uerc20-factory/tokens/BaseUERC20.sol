// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@solady/src/tokens/ERC20.sol";
import {IERC20} from "@openzeppelin-latest/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin-latest/contracts/interfaces/IERC165.sol";
import {IERC20Permit} from "@openzeppelin-latest/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {UERC20Metadata, UERC20MetadataLibrary} from "../libraries/UERC20MetadataLibrary.sol";

/// @title BaseUERC20
/// @notice ERC20 token contract
/// @dev Uses solady for default permit2 approval
/// @dev Implementing contract should initialise global variables and mint any initial supply
abstract contract BaseUERC20 is ERC20, IERC165 {
    using UERC20MetadataLibrary for UERC20Metadata;

    /// @dev Cached hash of the token name for gas-efficient EIP-712 operations.
    /// This immutable value is computed once during construction and used by the
    /// underlying ERC20 implementation for permit functionality.
    bytes32 internal immutable _nameHash;

    // Core parameters that define token identity
    bytes32 public immutable graffiti;
    address public immutable creator;
    uint8 internal immutable _decimals;
    string internal _name;
    string internal _symbol;
    // Metadata that may have extended information
    UERC20Metadata public metadata;

    /// @notice Returns the URI of the token metadata.
    function tokenURI() external view returns (string memory) {
        return metadata.toJSON();
    }

    /// @notice Returns the name of the token.
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @notice Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice Returns the decimals places of the token.
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) public view virtual returns (bool) {
        return _interfaceId == type(IERC165).interfaceId || _interfaceId == type(IERC20).interfaceId
            || _interfaceId == type(IERC20Permit).interfaceId;
    }

    /// @inheritdoc ERC20
    function _constantNameHash() internal view override returns (bytes32) {
        return _nameHash;
    }
}
