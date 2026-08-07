// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IClaimableRecipient} from "../interfaces/IClaimableRecipient.sol";
import {BaseClaimRecipient} from "./BaseClaimRecipient.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

/// @title VestingClaimRecipient
/// @notice Contract which claims amounts from sources and releases them over time
/// @dev Supports claiming from multiple sources but attributes all amounts to the canoncial tokenId on PositionManager
contract VestingClaimRecipient is BaseClaimRecipient {
    uint128 public immutable maxCurrency0PerBlock;
    uint128 public immutable maxCurrency1PerBlock;

    IClaimableRecipient public immutable recipient;

    /// @notice The block number when the last claim was made for a given tokenId
    mapping(uint256 tokenId => uint256 lastClaimed) public lastClaimed;

    /// @notice Emitted when a beneficiary is renounced
    event BeneficiaryRenounced(uint256 indexed tokenId, IClaimableRecipient indexed recipient);

    constructor(
        IPositionManager _positionManager,
        uint128 _maxCurrency0PerBlock,
        uint128 _maxCurrency1PerBlock,
        IClaimableRecipient _recipient
    ) BaseClaimRecipient(_positionManager) {
        maxCurrency0PerBlock = _maxCurrency0PerBlock;
        maxCurrency1PerBlock = _maxCurrency1PerBlock;
        recipient = _recipient;
    }

    /// @notice Renounce ownership over a beneficiary NFT and transfer the NFT into this contract
    /// @param _beneficiaryVault The beneficiary vault to renounce ownership over
    /// @param _tokenId The tokenId of the beneficiary NFT
    function renounce(IBeneficiaryVault _beneficiaryVault, uint256 _tokenId) external {
        // Transfer into this contract, requires approval on the tokenId
        _beneficiaryVault.transferFrom(msg.sender, address(this), _tokenId);
        lastClaimed[_tokenId] = block.number;

        emit BeneficiaryRenounced(_tokenId, recipient);
    }

    /// @inheritdoc BaseClaimRecipient
    /// @notice Override to set a maximum cap on the amount of fees that can be claimed for a given tokenId in a time period
    function _beforeClaimTransfer(
        uint256 tokenId,
        Currency _currency0,
        Currency _currency1,
        uint256 _available0,
        uint256 _available1
    ) internal override {
        // Cap available amounts at the max per block for the given currency since last claim
        uint256 blocksPassed = block.number - lastClaimed[tokenId];
        // Don't reset the last claimed block if no blocks have passed
        if (blocksPassed == 0) return (recipient, 0, recipient, 0);
        lastClaimed[tokenId] = block.number;

        uint256 maxCurrency0 = maxCurrency0PerBlock * blocksPassed;
        uint256 maxCurrency1 = maxCurrency1PerBlock * blocksPassed;
        return (
            recipient,
            FixedPointMathLib.min(_available0, maxCurrency0),
            recipient,
            FixedPointMathLib.min(_available1, maxCurrency1)
        );
    }

    /// @inheritdoc BaseClaimRecipient
    /// @notice Calls `onAmountsReceived` on the recipient for the given tokenId to register the new balance
    function _afterClaim(PoolKey memory, uint256 _tokenId, uint256 _toSend0, uint256 _toSend1) internal override {
        state[_tokenId].recipient.onAmountsReceived(_tokenId, _toSend0, _toSend1);
    }

    /// @notice Receive ETH
    receive() external payable {}

    /// @notice Claims fees from a source for a given tokenId and accounts them to the canonical pool associated with the tokenId from the PositionManager
    /// @dev Only attributes to the canonical tokenId on PositionMananger.
    ///      Source contracts MUST ensure that their internal tokenId accounting is 1:1 with the V4 LP NFT id, otherwise amounts received here will be lost.
    function claimFor(
        IClaimableRecipient source,
        uint256 tokenId,
        uint128 minCurrency0Amount,
        uint128 minCurrency1Amount
    ) external {
        (uint128 currency0Amount, uint128 currency1Amount) = source.amounts(tokenId);
        // If the amounts are insufficient, revert
        if (currency0Amount < minCurrency0Amount || currency1Amount < minCurrency1Amount) revert InsufficientAmounts();
        // Claim the entire amount possible
        source.claim(tokenId, currency0Amount, currency1Amount);
        // Account the amount to the canonical pool associated with the tokenId from the PositionManager
        onAmountsReceived(tokenId, currency0Amount, currency1Amount);
    }
}
