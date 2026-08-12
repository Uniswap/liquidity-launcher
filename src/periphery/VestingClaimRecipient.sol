// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IClaimableRecipient} from "../interfaces/IClaimableRecipient.sol";
import {BaseClaimRecipient} from "./BaseClaimRecipient.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {IBeneficiaryVault} from "../interfaces/IBeneficiaryVault.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title VestingClaimRecipient
/// @notice Contract which claims amounts from allowed beneficiary vaults and releases the amounts over time
/// @dev This contract MUST hold the beneficiary NFTs before claiming can begin. Amounts can be attributed
///      before ownership is transferred to this contract but `claim` will be blocked.
/// @dev Assumes that beneficiary vaults are trusted to report amounts correctly, and that only one
///      beneficiary NFT has ever been issued for a given V4 position ID.
contract VestingClaimRecipient is BaseClaimRecipient, BlockNumberish, IERC721Receiver {
    /// @notice Thrown when the pinned recipient is zero or this contract
    /// @param recipient The invalid recipient
    error InvalidRecipient(IClaimableRecipient recipient);

    /// @notice Thrown when a vault reports less than the caller's required amounts
    error InsufficientAmounts();

    /// @notice Thrown when the maximum currency0 or currency1 amount per block is zero
    error MaxCurrencyAmountsCannotBeZero();

    /// @notice Thrown when this contract does not own the position on any of the allowed beneficiary vaults
    /// @param tokenId The position token ID
    error NotPositionOwner(uint256 tokenId);

    /// @notice Thrown when no allowlisted beneficiary vaults are set
    error MustSetAllowlistedBeneficiaryVaults();

    /// @notice Thrown when a beneficiary vault is not allowlisted
    /// @param beneficiaryVault The non-allowlisted beneficiary vault
    error NotAllowlistedBeneficiaryVault(IBeneficiaryVault beneficiaryVault);

    /// @notice Thrown when vesting has not started for a tokenId
    /// @param tokenId The position token ID
    error VestingNotStarted(uint256 tokenId);

    /// @notice Thrown when a beneficiary vault resolves positions against a different position manager
    /// @param positionManager The incompatible position manager
    /// @param expectedPositionManager The expected position manager
    error InvalidPositionManager(IPositionManager positionManager, IPositionManager expectedPositionManager);

    /// @notice The maximum currency0 amount releasable per block, per tokenId
    uint128 public immutable maxCurrency0PerBlock;

    /// @notice The maximum currency1 amount releasable per block, per tokenId
    uint128 public immutable maxCurrency1PerBlock;

    /// @notice The receiver of every release, fixed at deploy
    IClaimableRecipient public immutable recipient;

    /// @notice The block number when the last claim was made for a given tokenId, or zero if unclaimed
    mapping(uint256 tokenId => uint256 lastClaimed) public lastClaimed;

    /// @notice Emitted on the first claim for a tokenId
    event VestingStarted(uint256 indexed tokenId, uint256 startBlock);

    /// @notice The allowlisted beneficiary vaults, immutably set at construction
    IBeneficiaryVault[] public allowlistedBeneficiaryVaults;

    constructor(
        IPositionManager _positionManager,
        uint128 _maxCurrency0PerBlock,
        uint128 _maxCurrency1PerBlock,
        IClaimableRecipient _recipient,
        IBeneficiaryVault[] memory _allowlistedBeneficiaryVaults
    ) BaseClaimRecipient(_positionManager) {
        if (
            address(_recipient) == address(0) || address(_recipient) == address(this)
                || _recipient.positionManager() != _positionManager
        ) {
            revert InvalidRecipient(_recipient);
        }
        if (_maxCurrency0PerBlock == 0 || _maxCurrency1PerBlock == 0) {
            revert MaxCurrencyAmountsCannotBeZero();
        }
        maxCurrency0PerBlock = _maxCurrency0PerBlock;
        maxCurrency1PerBlock = _maxCurrency1PerBlock;
        recipient = _recipient;
        // Require at least one allowlisted beneficiary vault
        if (_allowlistedBeneficiaryVaults.length == 0) {
            revert MustSetAllowlistedBeneficiaryVaults();
        }
        for (uint256 i = 0; i < _allowlistedBeneficiaryVaults.length; i++) {
            IBeneficiaryVault beneficiaryVault = _allowlistedBeneficiaryVaults[i];
            if (beneficiaryVault.positionManager() != _positionManager) {
                revert InvalidPositionManager(beneficiaryVault.positionManager(), _positionManager);
            }
            allowlistedBeneficiaryVaults.push(beneficiaryVault);
        }
    }

    /// @inheritdoc IERC721Receiver
    /// @dev Accepts beneficiary NFTs so positions can be onboarded with `safeTransferFrom` as well as `transferFrom`
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Claims a beneficiary vault's attributed amounts for `_tokenId` and re-attributes them here, against the
    ///         canonical pool the position manager resolves for that same token ID
    /// @dev BeneficiaryVaults MUST keep their own token ID accounting 1:1 with the v4 LP NFT id, otherwise amounts
    ///      received here are lost. They MUST also pay out the full amount they report from `amounts`, so
    ///      `currency1` MUST be a standard token that does not take a fee on transfer.
    /// @param _beneficiaryVault The beneficiary vault to claim from
    /// @param _tokenId The token ID of the position
    /// @param _minCurrency0Amount The minimum acceptable currency0 amount
    /// @param _minCurrency1Amount The minimum acceptable currency1 amount
    function claimFrom(
        IBeneficiaryVault _beneficiaryVault,
        uint256 _tokenId,
        uint128 _minCurrency0Amount,
        uint128 _minCurrency1Amount
    ) external nonReentrant {
        // Require that the beneficiary vault is allowlisted
        if (!_isAllowlisted(_beneficiaryVault)) revert NotAllowlistedBeneficiaryVault(_beneficiaryVault);
        // Require that this contract owns the position on the beneficiary vault
        if (IERC721(address(_beneficiaryVault)).ownerOf(_tokenId) != address(this)) revert NotPositionOwner(_tokenId);

        (uint128 currency0Amount, uint128 currency1Amount) = _beneficiaryVault.amounts(_tokenId);
        if (currency0Amount < _minCurrency0Amount || currency1Amount < _minCurrency1Amount) {
            revert InsufficientAmounts();
        }

        // Set the lastClaimed block number for the tokenId if unset
        if (lastClaimed[_tokenId] == 0) {
            uint256 blockNumber = _getBlockNumberish();
            lastClaimed[_tokenId] = blockNumber;
            emit VestingStarted(_tokenId, blockNumber);
        }

        // claim everything the beneficiary vault reports, then attribute it against the canonical token ID
        _beneficiaryVault.claim(_tokenId, currency0Amount, currency1Amount);
        onAmountsReceived(_tokenId, currency0Amount, currency1Amount);
    }

    /// @inheritdoc BaseClaimRecipient
    /// @notice Override to cap the amounts released for a given tokenId by the time since its last claim
    /// @dev Requires that vesting has started for the tokenId, which is set in `claimFrom`
    function _beforeClaimTransfer(uint256 _tokenId, Currency, Currency, uint256 _available0, uint256 _available1)
        internal
        override
        returns (address, uint256, address, uint256)
    {
        uint256 last = lastClaimed[_tokenId];
        if (last == 0) revert VestingNotStarted(_tokenId);

        // Only update the lastClaimed if there is something to claim
        uint256 blockNumber = _getBlockNumberish();
        if (_available0 > 0 || _available1 > 0) {
            lastClaimed[_tokenId] = blockNumber;
        }

        // Transfer the minimum of the max claimable and the registered amounts in the contract.
        // Repeated calls in the same block will return zero.
        uint256 blocksPassed = blockNumber - last;
        return (
            address(recipient),
            FixedPointMathLib.min(_available0, maxCurrency0PerBlock * blocksPassed),
            address(recipient),
            FixedPointMathLib.min(_available1, maxCurrency1PerBlock * blocksPassed)
        );
    }

    /// @inheritdoc BaseClaimRecipient
    /// @notice Calls `onAmountsReceived` on the recipient to register the transferred amounts
    function _afterClaim(PoolKey memory, uint256 _tokenId, uint256 _toSend0, uint256 _toSend1) internal override {
        recipient.onAmountsReceived(_tokenId, _toSend0, _toSend1);
    }

    /// @notice Checks if a beneficiary vault is allowlisted
    /// @param _beneficiaryVault The beneficiary vault to check
    /// @return True if the beneficiary vault is allowlisted, false otherwise
    function _isAllowlisted(IBeneficiaryVault _beneficiaryVault) internal view returns (bool) {
        for (uint256 i = 0; i < allowlistedBeneficiaryVaults.length; i++) {
            if (address(allowlistedBeneficiaryVaults[i]) == address(_beneficiaryVault)) {
                return true;
            }
        }
        return false;
    }
}
