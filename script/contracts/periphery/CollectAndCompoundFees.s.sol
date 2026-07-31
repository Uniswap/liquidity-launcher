// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IClaimableRecipient} from "../../../src/interfaces/IClaimableRecipient.sol";
import {IFeeSplitter} from "../../../src/interfaces/IFeeSplitter.sol";
import {CompoundingClaimRecipient} from "../../../src/periphery/CompoundingClaimRecipient.sol";
import {CompoundingClaimExecutor} from "./CompoundingClaimExecutor.sol";
import {Parameters} from "../Parameters.sol";

/// @title CollectAndCompoundFeesScript
/// @notice Triggers a fee collect on FeeSplitter positions and compounds the CompoundingClaimRecipient's
///         share straight back into each position.
/// @dev The compound cannot be driven from an EOA: `CompoundingClaimRecipient.claim` calls its caller back
///      through `IClaimExecutor.onClaimed` and then requires the position's liquidity to have grown by at
///      least `MIN_LIQUIDITY_INCREASE`. This script deploys (CREATE2, idempotent) a
///      `CompoundingClaimExecutor` to satisfy that contract and calls it once per position.
///
/// Environment:
///   FEE_SPLITTER                 (address)  the FeeSplitter custodying the positions
///   COMPOUNDING_CLAIM_RECIPIENT  (address)  the CompoundingClaimRecipient receiving the callback split
///   TOKEN_IDS                    (uint256[], comma separated) positions to collect and compound
///   TOKEN_ID                     (uint256)  single-position alternative to TOKEN_IDS
///   CLAIM_EXECUTOR               (address, optional) reuse an executor instead of CREATE2-deploying one
///   LIQUIDITY_BUFFER_BPS         (uint256, optional, default 1) bps withheld from the computed liquidity
///   MIN_CURRENCY0_AMOUNT         (uint256, optional, default 0) claim floor for currency0
///   MIN_CURRENCY1_AMOUNT         (uint256, optional, default 0) claim floor for currency1
///
/// Usage:
///   forge script script/contracts/periphery/CollectAndCompoundFees.s.sol \
///     --rpc-url $RPC_URL --broadcast
///
/// Dry run (no --broadcast) simulates the full collect and compound against live state and logs the
/// liquidity each position would gain.
contract CollectAndCompoundFeesScript is Script, Parameters {
    /// @notice Default bps withheld from the computed liquidity to absorb the pool's round-up
    uint256 public constant DEFAULT_LIQUIDITY_BUFFER_BPS = 1;

    /// @notice Reads the configuration from the environment and compounds every configured position
    function run() public returns (address executor) {
        address feeSplitter = vm.envAddress("FEE_SPLITTER");
        address recipient = vm.envAddress("COMPOUNDING_CLAIM_RECIPIENT");
        if (feeSplitter == address(0)) revert("env: FEE_SPLITTER not set");
        if (recipient == address(0)) revert("env: COMPOUNDING_CLAIM_RECIPIENT not set");

        return run(feeSplitter, recipient, _tokenIds());
    }

    /// @notice Compounds an explicit set of positions
    /// @param feeSplitter The FeeSplitter custodying the positions
    /// @param recipient The CompoundingClaimRecipient receiving the callback-enabled split
    /// @param tokenIds The positions to collect and compound
    /// @return executor The executor used to drive the claims
    function run(address feeSplitter, address recipient, uint256[] memory tokenIds) public returns (address executor) {
        if (tokenIds.length == 0) revert("no token ids: set TOKEN_IDS or TOKEN_ID");

        executor = _deployExecutor(feeSplitter, recipient);

        uint256 minCurrency0Amount = vm.envOr("MIN_CURRENCY0_AMOUNT", uint256(0));
        uint256 minCurrency1Amount = vm.envOr("MIN_CURRENCY1_AMOUNT", uint256(0));

        for (uint256 i; i < tokenIds.length; i++) {
            _compound(CompoundingClaimExecutor(payable(executor)), tokenIds[i], minCurrency0Amount, minCurrency1Amount);
        }
    }

    /// @notice CREATE2-deploys the executor, or returns the already-deployed one at the same address.
    /// @dev The address is a pure function of the FeeSplitter, the recipient and the buffer, so a
    ///      re-run with the same configuration reuses the existing executor.
    function _deployExecutor(address feeSplitter, address recipient) private returns (address executor) {
        address configured = vm.envOr("CLAIM_EXECUTOR", address(0));
        if (configured != address(0)) {
            console.log("Using configured CompoundingClaimExecutor at", configured);
            return configured;
        }

        uint256 liquidityBufferBps = vm.envOr("LIQUIDITY_BUFFER_BPS", DEFAULT_LIQUIDITY_BUFFER_BPS);
        bytes memory bytecode = abi.encodePacked(
            type(CompoundingClaimExecutor).creationCode,
            abi.encode(IFeeSplitter(feeSplitter), IClaimableRecipient(recipient), liquidityBufferBps)
        );
        bytes32 salt = bytes32(0);
        address expectedAddress = Create2.computeAddress(salt, keccak256(bytecode), DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Using existing CompoundingClaimExecutor at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        executor = Create2.deploy(0, salt, bytecode);
        console.log("CompoundingClaimExecutor deployed to:", executor);
    }

    /// @notice Collects and compounds one position, logging the state either side of the call
    function _compound(
        CompoundingClaimExecutor executor,
        uint256 tokenId,
        uint256 minCurrency0Amount,
        uint256 minCurrency1Amount
    ) private {
        IPositionManager positionManager = executor.positionManager();
        uint128 minLiquidityIncrease =
            CompoundingClaimRecipient(payable(address(executor.recipient()))).MIN_LIQUIDITY_INCREASE();
        uint128 liquidityBefore = positionManager.getPositionLiquidity(tokenId);

        console.log("--- tokenId", tokenId);
        console.log("  position liquidity before:", liquidityBefore);
        console.log("  required liquidity increase:", minLiquidityIncrease);

        vm.broadcast();
        executor.collectAndCompound(tokenId, minCurrency0Amount, minCurrency1Amount);

        uint128 liquidityAfter = positionManager.getPositionLiquidity(tokenId);
        console.log("  position liquidity after:", liquidityAfter);
        console.log("  liquidity added:", liquidityAfter - liquidityBefore);
        _logResidualAttribution(executor, tokenId);
    }

    /// @notice Logs anything the claim left attributed to the position, which stays claimable next run
    function _logResidualAttribution(CompoundingClaimExecutor executor, uint256 tokenId) private view {
        (uint128 currency0Amount, uint128 currency1Amount) = executor.recipient().amounts(tokenId);
        if (currency0Amount != 0 || currency1Amount != 0) {
            console.log("  residual attributed currency0:", currency0Amount);
            console.log("  residual attributed currency1:", currency1Amount);
        }
    }

    /// @notice TOKEN_IDS if set, otherwise the single TOKEN_ID
    function _tokenIds() private view returns (uint256[] memory tokenIds) {
        tokenIds = vm.envOr("TOKEN_IDS", ",", new uint256[](0));
        if (tokenIds.length != 0) return tokenIds;

        tokenIds = new uint256[](1);
        tokenIds[0] = vm.envUint("TOKEN_ID");
    }
}
