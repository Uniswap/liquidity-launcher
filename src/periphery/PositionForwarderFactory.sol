// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IBeneficiaryVault} from "../interfaces/IBeneficiaryVault.sol";
import {PositionForwarder} from "./PositionForwarder.sol";

/// @title PositionForwarderFactory
/// @notice Deploys one PositionForwarder per beneficiary at a deterministic address.
/// @dev The address must be known before the launch exists: it goes into `MigratorParameters` as
///      `positionRecipient`, and those parameters are hashed into the initializer salt, so they cannot be
///      changed afterwards. Deployment can still wait until after migration — the PositionManager mints with
///      solmate `_mint`, which has no receiver callback, so positions can be minted to a codeless address.
///      A forwarder is keyed on its beneficiary alone and is reused across that beneficiary's launches.
/// @custom:security-contact security@uniswap.org
contract PositionForwarderFactory {
    /// @notice The canonical v4 PositionManager passed to every forwarder.
    IPositionManager public immutable positionManager;

    /// @notice The vault every forwarder registers beneficiaries with.
    IBeneficiaryVault public immutable vault;

    /// @notice The custodian every forwarder forwards positions to.
    address public immutable feeSplitter;

    /// @notice Emitted when a forwarder is deployed.
    /// @param beneficiary The beneficiary it serves.
    /// @param forwarder The deployed forwarder.
    event ForwarderDeployed(address indexed beneficiary, address forwarder);

    /// @param _positionManager The canonical v4 PositionManager.
    /// @param _vault The vault forwarders register with.
    /// @param _feeSplitter The custodian forwarders forward to.
    constructor(IPositionManager _positionManager, IBeneficiaryVault _vault, address _feeSplitter) {
        positionManager = _positionManager;
        vault = _vault;
        feeSplitter = _feeSplitter;
    }

    /// @notice The address `beneficiary`'s forwarder has, deployed or not.
    /// @param beneficiary The beneficiary to look up.
    /// @return forwarder The deterministic forwarder address.
    function predict(address beneficiary) public view returns (address forwarder) {
        forwarder = Create2.computeAddress(_salt(beneficiary), keccak256(_initCode(beneficiary)));
    }

    /// @notice Deploys `beneficiary`'s forwarder, or returns it if it already exists.
    /// @param beneficiary The beneficiary to deploy for.
    /// @return forwarder The forwarder serving `beneficiary`.
    function deploy(address beneficiary) public returns (PositionForwarder forwarder) {
        address predicted = predict(beneficiary);
        if (predicted.code.length != 0) return PositionForwarder(predicted);

        forwarder = PositionForwarder(Create2.deploy(0, _salt(beneficiary), _initCode(beneficiary)));
        emit ForwarderDeployed(beneficiary, address(forwarder));
    }

    /// @notice Deploys `beneficiary`'s forwarder if needed and flushes the positions it holds.
    /// @dev The single call a keeper makes once a launch has migrated.
    /// @param beneficiary The beneficiary whose forwarder holds the positions.
    /// @param tokenIds The positions to register and forward.
    function deployAndFlush(address beneficiary, uint256[] calldata tokenIds) external {
        deploy(beneficiary).flush(tokenIds);
    }

    /// @notice The CREATE2 salt for `beneficiary`'s forwarder.
    function _salt(address beneficiary) private pure returns (bytes32) {
        return keccak256(abi.encode(beneficiary));
    }

    /// @notice The creation code for `beneficiary`'s forwarder.
    function _initCode(address beneficiary) private view returns (bytes memory) {
        return abi.encodePacked(
            type(PositionForwarder).creationCode, abi.encode(positionManager, vault, feeSplitter, beneficiary)
        );
    }
}
