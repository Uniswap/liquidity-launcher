// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUERC20BeneficiaryVault} from "../interfaces/IUERC20BeneficiaryVault.sol";
import {IUERC20} from "../interfaces/external/IUERC20.sol";
import {BeneficiaryVault} from "./BeneficiaryVault.sol";

/// @title UERC20BeneficiaryVault
/// @notice A BeneficiaryVault whose unregistered positions can be claimed by the creator of the
///         launcher-created UERC20 they pair, proven through that token's graffiti.
/// @dev For positions whose custodian never registered a beneficiary. The first proven claim mints the
///      creator the NFT; later claims run the base owner check. Graffiti records the LiquidityLauncher
///      caller, so for a token created through an aggregator, the aggregator is the prover.
contract UERC20BeneficiaryVault is IUERC20BeneficiaryVault, BeneficiaryVault {
    /// @param _positionManager The canonical v4 PositionManager, also used for registration custody proofs.
    /// @param _nativeFallback The receiver for unregistered positions' native fee shares.
    /// @param _tokenFallback The receiver for unregistered positions' token fee shares.
    constructor(IPositionManager _positionManager, address _nativeFallback, address _tokenFallback)
        BeneficiaryVault(_positionManager, _nativeFallback, _tokenFallback)
    {}

    /// @inheritdoc BeneficiaryVault
    /// @dev Mints the beneficiary NFT to an unregistered position's claimer when their graffiti matches
    ///      either currency's token.
    function _beforeClaimTransfer(
        uint256 tokenId,
        Currency currency0,
        Currency currency1,
        uint256 available0,
        uint256 available1
    ) internal override returns (address, uint256, address, uint256) {
        if (_ownerOf(tokenId) == address(0)) {
            bytes32 callerGraffiti = keccak256(abi.encode(msg.sender));
            bytes32 graffiti0 = _graffitiOf(currency0);
            bytes32 graffiti1 = _graffitiOf(currency1);

            // Minting retires the graffiti proof; ownership can never return to address(0).
            if (graffiti0 == callerGraffiti || graffiti1 == callerGraffiti) _mint(msg.sender, tokenId);
            else if (graffiti0 != bytes32(0) || graffiti1 != bytes32(0)) revert NotTokenCreator(tokenId, msg.sender);
        }

        return super._beforeClaimTransfer(tokenId, currency0, currency1, available0, available1);
    }

    /// @notice Reads `currency`'s graffiti, returning bytes32(0) when not set
    function _graffitiOf(Currency currency) private view returns (bytes32 graffiti) {
        if (currency.isAddressZero()) return bytes32(0);
        (bool success, bytes memory data) = Currency.unwrap(currency).staticcall(abi.encodeCall(IUERC20.graffiti, ()));
        if (success && data.length == 32) return abi.decode(data, (bytes32));
        return bytes32(0);
    }
}
