// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseUERC20} from "../tokens/BaseUERC20.sol";
import {IUSUPERC20Factory} from "../interfaces/IUSUPERC20Factory.sol";
import {IERC7802, IERC165} from "@optimism/interfaces/L2/IERC7802.sol";
import {Predeploys} from "@optimism/src/libraries/Predeploys.sol";

/// @title USUPERC20
/// @notice ERC20 token contract that is Superchain interop compatible
contract USUPERC20 is BaseUERC20, IERC7802 {
    /// @dev The address of the Superchain Token Bridge (0x4200000000000000000000000000000000000028)
    address public constant SUPERCHAIN_TOKEN_BRIDGE = Predeploys.SUPERCHAIN_TOKEN_BRIDGE;

    /// @dev The chain where totalSupply is minted and metadata is stored
    uint256 public immutable homeChainId;

    /// @notice Thrown when the caller is not the Superchain Token Bridge
    error NotSuperchainTokenBridge(address sender, address bridge);

    /// @notice Thrown when the recipient is the zero address
    error RecipientCannotBeZeroAddress();

    constructor() {
        IUSUPERC20Factory.Parameters memory params = IUSUPERC20Factory(msg.sender).getParameters();

        _name = params.name;
        _nameHash = keccak256(bytes(_name));
        _symbol = params.symbol;
        _decimals = params.decimals;
        homeChainId = params.homeChainId;
        creator = params.creator;
        graffiti = params.graffiti;
        metadata = params.metadata;

        // Mint tokens only on the home chain to ensure the total supply remains consistent across all chains
        if (block.chainid == params.homeChainId) {
            _mint(params.recipient, params.totalSupply);
        }
    }

    /// @notice Reverts if the caller is not the Superchain Token Bridge
    modifier onlySuperchainTokenBridge() {
        if (msg.sender != Predeploys.SUPERCHAIN_TOKEN_BRIDGE) {
            revert NotSuperchainTokenBridge(msg.sender, Predeploys.SUPERCHAIN_TOKEN_BRIDGE);
        }
        _;
    }

    /// @inheritdoc IERC7802
    function crosschainMint(address _to, uint256 _amount) external onlySuperchainTokenBridge {
        if (_to == address(0)) {
            revert RecipientCannotBeZeroAddress();
        }
        _mint(_to, _amount);

        emit CrosschainMint(_to, _amount, msg.sender);
    }

    /// @inheritdoc IERC7802
    function crosschainBurn(address _from, uint256 _amount) external onlySuperchainTokenBridge {
        _burn(_from, _amount);

        emit CrosschainBurn(_from, _amount, msg.sender);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 _interfaceId) public view virtual override(BaseUERC20, IERC165) returns (bool) {
        return super.supportsInterface(_interfaceId) || _interfaceId == type(IERC7802).interfaceId;
    }
}
