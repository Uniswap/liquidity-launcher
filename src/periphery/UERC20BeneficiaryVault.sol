// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUERC20BeneficiaryVault} from "../interfaces/IUERC20BeneficiaryVault.sol";
import {IUERC20} from "../interfaces/external/IUERC20.sol";
import {BeneficiaryVault} from "./BeneficiaryVault.sol";

/// @title UERC20BeneficiaryVault
/// @notice A BeneficiaryVault whose unregistered positions can also be claimed by the creator of the
///         UERC20 token based on the token's immutable graffiti.
/// @dev This contract is NOT intended to be used by aggregator contracts like Multicall3 as
///      the `graffiti` could be set to a contract which cannot receive ETH.
contract UERC20BeneficiaryVault is IUERC20BeneficiaryVault, BeneficiaryVault {
    using CurrencyLibrary for Currency;

    /// @param _positionManager The canonical v4 PositionManager
    /// @param _nativeFallback Trusted receiver for unregistered positions' native fee shares
    /// @param _tokenFallback Receiver for unregistered positions' token fee shares
    constructor(IPositionManager _positionManager, address _nativeFallback, address _tokenFallback)
        BeneficiaryVault(_positionManager, _nativeFallback, _tokenFallback)
    {}

    /// @inheritdoc BeneficiaryVault
    /// @dev Supports claiming ownership via the token's graffiti
    function _beforeClaimTransfer(
        uint256 _tokenId,
        Currency _currency0,
        Currency _currency1,
        uint256 _available0,
        uint256 _available1
    ) internal override returns (address, uint256, address, uint256) {
        if (_ownerOf(_tokenId) == address(0)) {
            bytes32 callerGraffiti = keccak256(abi.encode(msg.sender));
            bytes32 graffiti0 = _graffitiOf(_currency0);
            bytes32 graffiti1 = _graffitiOf(_currency1);

            // Registering here rather than paying out directly leaves the creator a transferable NFT
            if (graffiti0 == callerGraffiti || graffiti1 == callerGraffiti) _mint(msg.sender, _tokenId);
            else if (graffiti0 != bytes32(0) || graffiti1 != bytes32(0)) revert NotTokenCreator(_tokenId, msg.sender);
        }

        return super._beforeClaimTransfer(_tokenId, _currency0, _currency1, _available0, _available1);
    }

    /// @notice Reads `_currency`'s graffiti if set
    /// @return graffiti Any graffiti value set on the deployed token contract. See `IUERC20.graffiti()`.
    function _graffitiOf(Currency _currency) private view returns (bytes32 graffiti) {
        if (_currency.isAddressZero()) return bytes32(0);
        (bool success, bytes memory data) =
            address(Currency.unwrap(_currency)).staticcall(abi.encodeWithSelector(IUERC20.graffiti.selector));
        if (success && data.length == 32) return abi.decode(data, (bytes32));
        return bytes32(0);
    }
}
