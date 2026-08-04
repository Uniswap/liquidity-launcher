// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {IBeneficiaryVault} from "../interfaces/IBeneficiaryVault.sol";
import {BaseClaimRecipient} from "./BaseClaimRecipient.sol";

/// @title BeneficiaryVault
/// @notice Pull-based fee recipient whose transferable ERC721 represents a position's beneficiary.
/// @dev Fallbacks must accept plain native transfers; a beneficiary that cannot can move the NFT to one that can.
contract BeneficiaryVault is IBeneficiaryVault, BaseClaimRecipient, ERC721 {
    using CurrencyLibrary for Currency;

    /// @inheritdoc IBeneficiaryVault
    address public immutable override nativeFallback;

    /// @inheritdoc IBeneficiaryVault
    address public immutable override tokenFallback;

    /// @param _positionManager The canonical v4 PositionManager, also used for registration custody proofs.
    /// @param _nativeFallback Trusted receiver for unregistered positions' native fee shares.
    /// @param _tokenFallback Receiver for unregistered positions' token fee shares.
    constructor(IPositionManager _positionManager, address _nativeFallback, address _tokenFallback)
        BaseClaimRecipient(_positionManager)
    {
        if (_nativeFallback == address(0) || _nativeFallback == address(this)) revert InvalidFallback(_nativeFallback);
        if (_tokenFallback == address(0) || _tokenFallback == address(this)) revert InvalidFallback(_tokenFallback);
        nativeFallback = _nativeFallback;
        tokenFallback = _tokenFallback;
    }

    /// @inheritdoc IBeneficiaryVault
    function registerBeneficiary(uint256 tokenId, address beneficiary) external virtual override {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != msg.sender) {
            revert NotPositionOwner(tokenId, msg.sender);
        }
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary(beneficiary);
        if (_ownerOf(tokenId) != address(0)) _burn(tokenId);
        _mint(beneficiary, tokenId);
    }

    /// @inheritdoc BaseClaimRecipient
    /// @dev The beneficiary NFT owner receives the full amounts; an approved operator may trigger
    ///      the claim on the owner's behalf. Unregistered positions pay out to the per-side fallbacks.
    function _beforeClaimTransfer(
        uint256 _tokenId,
        Currency _currency0,
        Currency,
        uint256 _available0,
        uint256 _available1
    ) internal virtual override returns (address, uint256, address, uint256) {
        address owner = _ownerOf(_tokenId);
        if (owner == address(0)) {
            // currency1 can never be native in v4, so its fallback is always the token fallback.
            return
                (_currency0.isAddressZero() ? nativeFallback : tokenFallback, _available0, tokenFallback, _available1);
        }
        if (!_isApprovedOrOwner(msg.sender, _tokenId)) revert NotApprovedOrOwner(_tokenId, msg.sender);
        return (owner, _available0, owner, _available1);
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
