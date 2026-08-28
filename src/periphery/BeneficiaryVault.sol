// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {IBeneficiaryVault} from "../interfaces/IBeneficiaryVault.sol";
import {BaseClaimRecipient} from "./BaseClaimRecipient.sol";

/// @title BeneficiaryVault
/// @notice Pull-based fee recipient whose transferable ERC721 represents a position's beneficiary.
/// @dev Fallbacks must accept plain native transfers; a beneficiary that cannot can move the NFT to one that can.
contract BeneficiaryVault is IBeneficiaryVault, BaseClaimRecipient, ERC721 {
    /// @inheritdoc IBeneficiaryVault
    Currency public immutable override quoteCurrency;

    /// @inheritdoc IBeneficiaryVault
    address public immutable override quoteFallback;

    /// @inheritdoc IBeneficiaryVault
    address public immutable override tokenFallback;

    /// @param _positionManager The canonical v4 PositionManager, also used for registration custody proofs.
    /// @param _quoteCurrency The quote currency whose fee shares route to the quote fallback.
    /// @param _quoteFallback Trusted receiver for unregistered positions' quote currency fee shares.
    /// @param _tokenFallback Receiver for unregistered positions' token-side fee shares.
    constructor(
        IPositionManager _positionManager,
        Currency _quoteCurrency,
        address _quoteFallback,
        address _tokenFallback
    ) BaseClaimRecipient(_positionManager) {
        if (_quoteFallback == address(0) || _quoteFallback == address(this)) {
            revert InvalidFallback(_quoteFallback);
        }
        if (_tokenFallback == address(0) || _tokenFallback == address(this)) revert InvalidFallback(_tokenFallback);
        quoteCurrency = _quoteCurrency;
        quoteFallback = _quoteFallback;
        tokenFallback = _tokenFallback;
    }

    /// @inheritdoc IBeneficiaryVault
    function registerBeneficiary(uint256 tokenId, address beneficiary) external virtual override {
        if (_exists(tokenId)) revert ERC721.TokenAlreadyExists();
        if (IERC721(address(positionManager)).ownerOf(tokenId) != msg.sender) {
            revert NotPositionOwner(tokenId, msg.sender);
        }
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary(beneficiary);
        _mint(beneficiary, tokenId);
    }

    /// @inheritdoc BaseClaimRecipient
    /// @dev The owner of the beneficiary NFT receives the full amounts; unregistered positions pay out
    ///      to the per-side fallbacks.
    function _beforeClaimTransfer(
        uint256 _tokenId,
        Currency _currency0,
        Currency _currency1,
        uint256 _available0,
        uint256 _available1
    ) internal virtual override returns (address, uint256, address, uint256) {
        address owner = _ownerOf(_tokenId);
        if (owner == address(0)) {
            // Each side routes by whether it is the quote currency; both sides of a pool without the
            // quote route to the token fallback.
            return (
                _currency0 == quoteCurrency ? quoteFallback : tokenFallback,
                _available0,
                _currency1 == quoteCurrency ? quoteFallback : tokenFallback,
                _available1
            );
        }
        if (msg.sender != owner) revert NotBeneficiary(_tokenId, msg.sender);
        return (msg.sender, _available0, msg.sender, _available1);
    }

    /// @inheritdoc ERC721
    function name() public pure override returns (string memory) {
        return "Fee Beneficiary";
    }

    /// @inheritdoc ERC721
    function symbol() public pure override returns (string memory) {
        return "FEEB";
    }

    /// @inheritdoc ERC721
    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
}
