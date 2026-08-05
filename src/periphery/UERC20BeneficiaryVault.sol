// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUERC20} from "../interfaces/external/IUERC20.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {BeneficiaryVault} from "./BeneficiaryVault.sol";

/// @title UERC20BeneficiaryVault
/// @notice A BeneficiaryVault whose unregistered positions can also be registered by the creator of the
///         UERC20 token based on the token's graffiti.
/// @dev Tokens with graffiti set to a public aggregator contract like Multicall3 are NOT supported.
/// @dev MUST NOT be used for positions whose pool pairs two tokens that both expose `graffiti()`.
///      Either token's creator passes the registration check, so whichever claims first receives both
///      currency sides and keeps the transferable beneficiary NFT.
/// @dev If a contract is intended to be the beneficiary, it MUST be able to call `claim`
///      or transfer the beneficiary NFT in order to receive accrued amounts.
contract UERC20BeneficiaryVault is BeneficiaryVault {
    using CurrencyLibrary for Currency;

    /// @notice Thrown when the caller is not authorized for the position.
    /// @param tokenId The position token ID.
    /// @param caller The unauthorized caller.
    error NotAuthorized(uint256 tokenId, address caller);

    /// @param _positionManager The canonical v4 PositionManager
    /// @param _nativeFallback Trusted receiver for unregistered positions' native fee shares
    /// @param _tokenFallback Receiver for unregistered positions' token fee shares
    constructor(IPositionManager _positionManager, address _nativeFallback, address _tokenFallback)
        BeneficiaryVault(_positionManager, _nativeFallback, _tokenFallback)
    {}

    /// @notice Override the BeneficiaryVault's registerBeneficiary to also support registering
    ///         positions via checking the token's graffiti.
    /// @notice Supports both synchronous (atomic register + transfer) and asynchronous registration.
    /// @dev If the token's graffiti is a public aggregator contract like Multicall3,
    ///      this function MUST be called in the same transaction as the position's creation
    ///      otherwise the beneficiary NFT can be claimed by anyone.
    function registerBeneficiary(uint256 tokenId, address beneficiary) public override(BeneficiaryVault) {
        // Never have two beneficiary NFTs for the same position. Transferring should be done via ERC721.transferFrom
        if (_exists(tokenId)) revert ERC721.TokenAlreadyExists();
        // Reject invalid beneficiary addresses
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary(beneficiary);
        // Always allow position owner to set beneficiary regardless of graffiti
        if (IERC721(address(positionManager)).ownerOf(tokenId) == msg.sender) {
            _mint(beneficiary, tokenId);
        } else {
            // Async registration is only supported for the original creator of the position within UERC20.graffiti()
            if (!_isTokenCreator(msg.sender, tokenId)) revert NotAuthorized(tokenId, msg.sender);
            _mint(beneficiary, tokenId);
        }
    }

    /// @inheritdoc BeneficiaryVault
    /// @dev Unregistered UERC20 positions cannot be claimed until `register` mints the beneficiary NFT.
    ///      Positions with no launcher graffiti still flush to the fallbacks.
    function _beforeClaimTransfer(
        uint256 tokenId,
        Currency currency0,
        Currency currency1,
        uint256 available0,
        uint256 available1
    ) internal override returns (address, uint256, address, uint256) {
        // If the tokens have graffiti but the position is not registered
        if (!_exists(tokenId) && (_graffitiOf(currency0) != bytes32(0) || _graffitiOf(currency1) != bytes32(0))) {
            // otherwise, register the position
            registerBeneficiary(tokenId, msg.sender);
        }
        return super._beforeClaimTransfer(tokenId, currency0, currency1, available0, available1);
    }

    /// @notice Checks if `caller` matches either side's UERC20 graffiti.
    /// @dev Matching either side is sufficient, so a pool pairing two tokens with distinct creators
    ///      authorizes both of them and is NOT supported.
    function _isTokenCreator(address caller, uint256 tokenId) private view returns (bool) {
        PoolKey memory poolKey = _getPoolKey(tokenId);
        bytes32 callerGraffiti = keccak256(abi.encode(caller));
        return callerGraffiti == _graffitiOf(poolKey.currency0) || callerGraffiti == _graffitiOf(poolKey.currency1);
    }

    /// @notice Reads `_currency`'s graffiti if set.
    /// @return graffiti Any graffiti value set on the deployed token contract. See `IUERC20.graffiti()`.
    function _graffitiOf(Currency _currency) private view returns (bytes32 graffiti) {
        if (_currency.isAddressZero()) return bytes32(0);
        (bool success, bytes memory data) =
            address(Currency.unwrap(_currency)).staticcall(abi.encodeWithSelector(IUERC20.graffiti.selector));
        if (success && data.length == 32) return abi.decode(data, (bytes32));
        return bytes32(0);
    }
}
