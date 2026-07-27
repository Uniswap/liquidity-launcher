// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IGraffitiBeneficiaryVault} from "../interfaces/IGraffitiBeneficiaryVault.sol";
import {IUERC20} from "../interfaces/external/IUERC20.sol";
import {BeneficiaryVault} from "./BeneficiaryVault.sol";

/// @title GraffitiBeneficiaryVault
/// @notice A BeneficiaryVault whose unregistered positions can be claimed by the creator of the
///         launcher-created token they pair, proven through that token's graffiti.
/// @dev A temporary bridge for strategies that predate this vault and therefore never register a
///      beneficiary while they custody the position. Claims proven this way mint no NFT, so the stream
///      cannot be sold or moved. Graffiti records whoever called the LiquidityLauncher, so for a token
///      created through an aggregator that aggregator is the prover, and anyone able to route a call
///      through it can claim.
contract GraffitiBeneficiaryVault is IGraffitiBeneficiaryVault, BeneficiaryVault {
    using CurrencyLibrary for Currency;

    /// @param _positionManager The canonical v4 PositionManager, also used for registration custody proofs.
    /// @param _nativeFallback Trusted receiver for unregistered positions' native fee shares.
    /// @param _tokenFallback Receiver for unregistered positions' token fee shares.
    constructor(IPositionManager _positionManager, address _nativeFallback, address _tokenFallback)
        BeneficiaryVault(_positionManager, _nativeFallback, _tokenFallback)
    {}

    /// @inheritdoc BeneficiaryVault
    /// @dev Registered positions keep the base's NFT semantics. An unregistered position pays the caller
    ///      when they are the creator of either paired token, and otherwise reverts rather than flushing
    ///      to the fallbacks, so nobody can push an unclaimed creator share away before they claim.
    function _beforeClaimTransfer(
        uint256 _tokenId,
        Currency _currency0,
        Currency _currency1,
        uint256 _available0,
        uint256 _available1
    ) internal view override returns (address recipient0, uint256 toSend0, address recipient1, uint256 toSend1) {
        if (_ownerOf(_tokenId) != address(0)) {
            return super._beforeClaimTransfer(_tokenId, _currency0, _currency1, _available0, _available1);
        }

        bytes32 callerGraffiti = keccak256(abi.encode(msg.sender));
        (bool isLauncherToken0, bool isCreator0) = _readGraffiti(_currency0, callerGraffiti);
        (bool isLauncherToken1, bool isCreator1) = _readGraffiti(_currency1, callerGraffiti);

        if (isCreator0 || isCreator1) return (msg.sender, _available0, msg.sender, _available1);
        if (isLauncherToken0 || isLauncherToken1) revert NotTokenCreator(_tokenId, msg.sender);

        return super._beforeClaimTransfer(_tokenId, _currency0, _currency1, _available0, _available1);
    }

    /// @notice Reads `_currency`'s graffiti, tolerating currencies that do not expose one.
    /// @return isLauncherToken Whether the currency exposes a graffiti at all.
    /// @return isCreator Whether that graffiti matches `_callerGraffiti`.
    function _readGraffiti(Currency _currency, bytes32 _callerGraffiti)
        private
        view
        returns (bool isLauncherToken, bool isCreator)
    {
        if (_currency.isAddressZero()) return (false, false);
        try IUERC20(Currency.unwrap(_currency)).graffiti() returns (bytes32 graffiti) {
            return (true, graffiti == _callerGraffiti);
        } catch {
            return (false, false);
        }
    }
}
