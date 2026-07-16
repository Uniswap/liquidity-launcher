// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IDirectLaunchStrategy} from "../interfaces/IDirectLaunchStrategy.sol";
import {PositionPlanner} from "./PositionPlanner.sol";
import {PoolParameters} from "./MigratorParams.sol";
import {PositionDefinition} from "../types/PositionPlannerTypes.sol";

/// @notice Launch parameters for a direct-to-pool distribution
struct DirectLaunchParameters {
    address currency; // pool currency paired with the token; native is address(0). Must differ from the token
    uint160 initialSqrtPriceX96; // pool initialization price
    address recipient; // the address that receives unplaced tokens after launch
    address positionRecipient; // default recipient of minted LP positions
    PoolParameters poolParameters;
    bytes positionDefinitions; // abi-encoded PositionDefinition[]; weights must sum to exactly 1e7 (100% in mps)
    bytes launchConfig; // abi-encoded LaunchConfig; required iff poolParameters.hook supports ILaunchHook
}

/// @title DirectLaunchParams
/// @notice Validation helpers for DirectLaunchParameters, including the single-sided position plan
library DirectLaunchParams {
    /// @notice Validates the full launch parameters struct. Reverts on any invalidity.
    /// @dev The position plan must allocate exactly 100% of the supplied token amount and every position
    ///      must sit entirely on the token side of the initial price (see PositionPlanner.validateSingleSided).
    /// @param p The launch parameters to validate
    /// @param token The token being launched
    /// @param tokenIsCurrency0 Whether the token orders as currency0 against p.currency
    function validate(DirectLaunchParameters memory p, address token, bool tokenIsCurrency0) internal pure {
        if (token == p.currency) revert IDirectLaunchStrategy.InvalidTokenCurrencyPair(token);

        if (
            p.poolParameters.tickSpacing > TickMath.MAX_TICK_SPACING
                || p.poolParameters.tickSpacing < TickMath.MIN_TICK_SPACING
        ) {
            revert IDirectLaunchStrategy.InvalidTickSpacing(
                p.poolParameters.tickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING
            );
        }
        if (p.poolParameters.fee > LPFeeLibrary.MAX_LP_FEE && p.poolParameters.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG) {
            revert IDirectLaunchStrategy.InvalidFee(p.poolParameters.fee, LPFeeLibrary.MAX_LP_FEE);
        }
        if (p.poolParameters.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG && p.poolParameters.hook == address(0)) {
            revert IDirectLaunchStrategy.InvalidDynamicFeeHook();
        }
        if (p.recipient == address(0)) {
            revert IDirectLaunchStrategy.InvalidRecipient();
        }
        if (
            p.positionRecipient == address(0) || p.positionRecipient == ActionConstants.MSG_SENDER
                || p.positionRecipient == ActionConstants.ADDRESS_THIS
        ) {
            revert IDirectLaunchStrategy.InvalidPositionRecipient(p.positionRecipient);
        }

        PositionDefinition[] memory definitions = abi.decode(p.positionDefinitions, (PositionDefinition[]));
        // With no currency budget the implicit full-range fallback cannot absorb unallocated supply, so the
        // explicit definitions must place all of it.
        uint256 totalWeight = PositionPlanner.validate(definitions);
        if (totalWeight != PositionPlanner.MPS) revert IDirectLaunchStrategy.IncompleteAllocation(totalWeight);

        PositionPlanner.validateSingleSided(
            definitions, p.initialSqrtPriceX96, p.poolParameters.tickSpacing, tokenIsCurrency0
        );
    }
}
