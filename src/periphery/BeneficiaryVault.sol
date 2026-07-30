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
/// @dev Fallbacks and beneficiaries must accept plain native transfers.
contract BeneficiaryVault is IBeneficiaryVault, BaseClaimRecipient, ERC721 {
    /// @inheritdoc IBeneficiaryVault
    address public immutable override nativeFallback;

    /// @inheritdoc IBeneficiaryVault
    address public immutable override tokenFallback;

    /// @param _positionManager The canonical v4 PositionManager, also used for registration custody proofs.
    /// @param _nativeFallback The receiver for unregistered positions' native fee shares.
    /// @param _tokenFallback The receiver for unregistered positions' token fee shares.
    constructor(IPositionManager _positionManager, address _nativeFallback, address _tokenFallback)
        BaseClaimRecipient(_positionManager)
    {
        if (_nativeFallback == address(0) || _nativeFallback == address(this)) revert InvalidFallback(_nativeFallback);
        if (_tokenFallback == address(0) || _tokenFallback == address(this)) revert InvalidFallback(_tokenFallback);
        nativeFallback = _nativeFallback;
        tokenFallback = _tokenFallback;
    }

    /// @inheritdoc IBeneficiaryVault
    function registerBeneficiary(uint256 tokenId, address beneficiary) external override {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != msg.sender) {
            revert NotPositionOwner(tokenId, msg.sender);
        }
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary(beneficiary);
        if (_ownerOf(tokenId) != address(0)) _burn(tokenId);
        _mint(beneficiary, tokenId);
    }

    /// @inheritdoc BaseClaimRecipient
    /// @dev The owner of the beneficiary NFT receives the full amounts; unregistered positions pay out
    ///      to the per-side fallbacks.
    function _beforeClaimTransfer(
        uint256 tokenId,
        Currency currency0,
        Currency currency1,
        uint256 available0,
        uint256 available1
    ) internal virtual override returns (address, uint256, address, uint256) {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) {
            // currency1 is never native in v4.
            return (currency0.isAddressZero() ? nativeFallback : tokenFallback, available0, tokenFallback, available1);
        }
        if (msg.sender != owner) revert NotBeneficiary(tokenId, msg.sender);
        return super._beforeClaimTransfer(tokenId, currency0, currency1, available0, available1);
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
