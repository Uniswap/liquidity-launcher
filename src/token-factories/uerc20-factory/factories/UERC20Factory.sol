// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UERC20} from "../tokens/UERC20.sol";
import {IUERC20Factory} from "../interfaces/IUERC20Factory.sol";
import {ITokenFactory} from "../interfaces/ITokenFactory.sol";
import {UERC20Metadata} from "../libraries/UERC20MetadataLibrary.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title UERC20Factory
/// @notice Deploys new UERC20 contracts
contract UERC20Factory is IUERC20Factory {
    /// @dev Parameters stored transiently for token initialization
    Parameters private parameters;

    /// @inheritdoc IUERC20Factory
    function getUERC20Address(
        string memory name,
        string memory symbol,
        uint8 decimals,
        address creator,
        bytes32 graffiti
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(name, symbol, decimals, creator, graffiti));
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(UERC20).creationCode));
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }

    /// @inheritdoc IUERC20Factory
    function getParameters() external view returns (Parameters memory) {
        return parameters;
    }

    /// @inheritdoc ITokenFactory
    function createToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 totalSupply,
        address recipient,
        bytes calldata data,
        bytes32 graffiti
    ) external returns (address tokenAddress) {
        (UERC20Metadata memory metadata) = abi.decode(data, (UERC20Metadata));

        if (recipient == address(0)) {
            revert RecipientCannotBeZeroAddress();
        }
        if (totalSupply == 0) {
            revert TotalSupplyCannotBeZero();
        }

        // Store parameters transiently for token to access during construction
        parameters = Parameters({
            name: name,
            symbol: symbol,
            totalSupply: totalSupply,
            recipient: recipient,
            decimals: decimals,
            creator: msg.sender,
            metadata: metadata,
            graffiti: graffiti
        });

        // Compute salt based on the core parameters that define a token's identity
        bytes32 salt = keccak256(abi.encode(name, symbol, decimals, msg.sender, graffiti));

        // Deploy the token with the computed salt
        tokenAddress = address(new UERC20{salt: salt}());

        // Clear parameters after deployment
        delete parameters;

        emit TokenCreated(tokenAddress);
    }
}
