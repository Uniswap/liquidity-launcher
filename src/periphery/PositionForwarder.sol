// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IBeneficiaryVault} from "../interfaces/IBeneficiaryVault.sol";

/// @title PositionForwarder
/// @notice Registers one fixed beneficiary for the LP positions it receives, then forwards them to the
///         FeeSplitter.
/// @dev Exists because a strategy that mints positions to a configured recipient — `LBPStrategy` through
///      `MigratorParameters.positionRecipient` — knows nothing about the BeneficiaryVault, so nothing with
///      custody ever registers a beneficiary. Naming this contract as that recipient supplies a custodian
///      which can register through the vault's existing custody proof.
///      Flow: `PositionForwarderFactory.predict` -> `positionRecipient` (leave every
///      `overridePositionRecipient` at zero; the default covers all definitions and the implicit full-range
///      fallback) -> create the launch -> after migration, `deployAndFlushCollect`.
/// @custom:security-contact security@uniswap.org
contract PositionForwarder {
    /// @notice The canonical v4 PositionManager holding the positions.
    IPositionManager public immutable positionManager;

    /// @notice The vault the beneficiary is registered with.
    IBeneficiaryVault public immutable vault;

    /// @notice The permanent custodian the positions are forwarded to.
    address public immutable feeSplitter;

    /// @notice The beneficiary registered for every position this contract forwards.
    address public immutable beneficiary;

    /// @notice Thrown when the beneficiary is the zero address.
    error ZeroBeneficiary();

    /// @notice Thrown when flush is called with no token IDs.
    error NoTokenIds();

    /// @notice Emitted for each position registered and forwarded.
    /// @param tokenId The position forwarded.
    /// @param beneficiary The beneficiary registered for it.
    event PositionForwarded(uint256 indexed tokenId, address indexed beneficiary);

    /// @param _positionManager The canonical v4 PositionManager.
    /// @param _vault The vault to register the beneficiary with.
    /// @param _feeSplitter The custodian to forward positions to.
    /// @param _beneficiary The beneficiary of every position forwarded by this contract.
    constructor(
        IPositionManager _positionManager,
        IBeneficiaryVault _vault,
        address _feeSplitter,
        address _beneficiary
    ) {
        if (_beneficiary == address(0)) revert ZeroBeneficiary();
        positionManager = _positionManager;
        vault = _vault;
        feeSplitter = _feeSplitter;
        beneficiary = _beneficiary;
    }

    /// @notice Registers `beneficiary` for each position and forwards it to the FeeSplitter.
    /// @dev Permissionless: the beneficiary is immutable, so the caller cannot influence the outcome. Takes
    ///      an array because one migration mints a whole weighted plan to the same recipient. Reverts unless
    ///      this contract holds every token ID, since the vault requires custody to register.
    /// @param tokenIds The positions to register and forward.
    function flush(uint256[] calldata tokenIds) external {
        uint256 count = tokenIds.length;
        if (count == 0) revert NoTokenIds();
        for (uint256 i; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            vault.registerBeneficiary(tokenId, beneficiary);
            IERC721(address(positionManager)).transferFrom(address(this), feeSplitter, tokenId);
            emit PositionForwarded(tokenId, beneficiary);
        }
    }
}
