// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {USUPERC20} from "../tokens/USUPERC20.sol";
import {IUSUPERC20Factory} from "../interfaces/IUSUPERC20Factory.sol";
import {ITokenFactory} from "../interfaces/ITokenFactory.sol";
import {UERC20Metadata} from "../libraries/UERC20MetadataLibrary.sol";
import {Create2} from "@openzeppelin-latest/contracts/utils/Create2.sol";

/// @title USUPERC20Factory
/// @notice Deploys new USUPERC20 contracts
contract USUPERC20Factory is IUSUPERC20Factory {
    /// @dev Parameters stored transiently for token initialization
    Parameters private parameters;

    /// @inheritdoc IUSUPERC20Factory
    function getUSUPERC20Address(
        string memory name,
        string memory symbol,
        uint8 decimals,
        uint256 homeChainId,
        address creator,
        bytes32 graffiti
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(name, symbol, decimals, homeChainId, creator, graffiti));
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(USUPERC20).creationCode));
        return Create2.computeAddress(salt, initCodeHash, address(this));
    }

    /// @inheritdoc IUSUPERC20Factory
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
        (uint256 homeChainId, address creator, UERC20Metadata memory metadata) =
            abi.decode(data, (uint256, address, UERC20Metadata));

        // Check validity only on home chain
        if (block.chainid == homeChainId) {
            // Only the creator can deploy a token on the home chain
            if (msg.sender != creator) {
                revert NotCreator(msg.sender, creator);
            }
            if (recipient == address(0)) {
                revert RecipientCannotBeZeroAddress();
            }
            if (totalSupply == 0) {
                revert TotalSupplyCannotBeZero();
            }
        }

        // Compute salt based on the core parameters that define a token's identity
        bytes32 salt = keccak256(abi.encode(name, symbol, decimals, homeChainId, creator, graffiti));

        // Clear metadata if the token is not on the home chain
        // Metadata is only stored on the home chain
        if (block.chainid != homeChainId) {
            metadata.description = "";
            metadata.website = "";
            metadata.image = "";
        }

        // Store parameters transiently for token to access during construction
        parameters = Parameters({
            name: name,
            symbol: symbol,
            totalSupply: totalSupply,
            homeChainId: homeChainId,
            recipient: recipient,
            decimals: decimals,
            creator: creator,
            metadata: metadata,
            graffiti: graffiti
        });

        // Deploy the token with the computed salt
        tokenAddress = address(new USUPERC20{salt: salt}());

        // Clear parameters after deployment
        delete parameters;

        emit TokenCreated(tokenAddress);
    }
}
