// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IUERC20BeneficiaryVault} from "../interfaces/IUERC20BeneficiaryVault.sol";
import {IUERC20} from "../interfaces/external/IUERC20.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {BeneficiaryVault} from "./BeneficiaryVault.sol";

/// @title UERC20BeneficiaryVault
/// @notice A BeneficiaryVault whose unregistered positions can also be registered by the creator of the
///         UERC20 token based on the token's immutable graffiti.
/// @dev Positions paired with a launcher-created UERC20 must call `register` before `claim`. This
///      contract is NOT intended for aggregator launches where graffiti names a contract that cannot
///      receive ETH; those creators should register via Multicall3, transfer the NFT to an EOA, then
///      claim.
contract UERC20BeneficiaryVault is IUERC20BeneficiaryVault, BeneficiaryVault {
    using CurrencyLibrary for Currency;

    /// @param _positionManager The canonical v4 PositionManager
    /// @param _nativeFallback Trusted receiver for unregistered positions' native fee shares
    /// @param _tokenFallback Receiver for unregistered positions' token fee shares
    constructor(IPositionManager _positionManager, address _nativeFallback, address _tokenFallback)
        BeneficiaryVault(_positionManager, _nativeFallback, _tokenFallback)
    {}

    /// @inheritdoc IUERC20BeneficiaryVault
    function register(uint256 tokenId) external {
        if (_exists(tokenId)) revert ERC721.TokenAlreadyExists();
        if (!_isTokenCreator(msg.sender, tokenId)) revert NotAuthorized(tokenId, msg.sender);
        _mint(msg.sender, tokenId);
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
        if (_ownerOf(tokenId) == address(0) && _hasLauncherGraffiti(currency0, currency1)) {
            revert NotAuthorized(tokenId, msg.sender);
        }
        return super._beforeClaimTransfer(tokenId, currency0, currency1, available0, available1);
    }

    /// @notice Returns whether either side of the pair reports launcher graffiti.
    function _hasLauncherGraffiti(Currency currency0, Currency currency1) private view returns (bool) {
        return _graffitiOf(currency0) != bytes32(0) || _graffitiOf(currency1) != bytes32(0);
    }

    /// @notice Checks if `caller` matches either side's UERC20 graffiti.
    /// @dev The edge case where both currencies have unique creators is NOT supported.
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
