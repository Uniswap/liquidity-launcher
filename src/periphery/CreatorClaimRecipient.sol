// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ICreatorClaimRecipient} from "../interfaces/ICreatorClaimRecipient.sol";
import {IUERC20} from "../interfaces/external/IUERC20.sol";
import {BaseClaimRecipient} from "./BaseClaimRecipient.sol";

/// @title CreatorClaimRecipient
/// @notice Pull-based fee recipient paying a native-ETH position's attributed native fees to the
///         creator hashed into the paired launcher-created token's graffiti.
/// @dev Native-only: the token side is never paid out, so only route native fee shares here.
contract CreatorClaimRecipient is ICreatorClaimRecipient, BaseClaimRecipient {
    using CurrencyLibrary for Currency;

    /// @param _positionManager The canonical v4 PositionManager.
    constructor(IPositionManager _positionManager) BaseClaimRecipient(_positionManager) {}

    /// @inheritdoc BaseClaimRecipient
    /// @dev Requires a native currency0 and a currency1 graffiti matching the caller's hash — the
    ///      derivation of LiquidityLauncher.getGraffiti. The graffiti is read with a raw staticcall so a
    ///      currency1 that answers with anything but a single word reports "not a creator" instead of
    ///      reverting the claim with an uncatchable decode error.
    function _beforeClaimTransfer(
        uint256 _tokenId,
        Currency _currency0,
        Currency _currency1,
        uint256 _available0,
        uint256
    ) internal view override returns (address recipient0, uint256 toSend0, address recipient1, uint256 toSend1) {
        if (!_currency0.isAddressZero()) revert NotNativePosition(_tokenId);

        (bool success, bytes memory data) = Currency.unwrap(_currency1).staticcall(abi.encodeCall(IUERC20.graffiti, ()));
        if (!success || data.length != 32 || abi.decode(data, (bytes32)) != keccak256(abi.encode(msg.sender))) {
            revert NotTokenCreator(_tokenId, msg.sender);
        }
        return (msg.sender, _available0, msg.sender, 0);
    }
}
