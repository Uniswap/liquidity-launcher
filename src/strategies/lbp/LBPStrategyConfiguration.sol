// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ILBPStrategy} from "../../interfaces/ILBPStrategy.sol";
import {ILBPStrategyConfiguration} from "../../interfaces/ILBPStrategyConfiguration.sol";

/// @title LBPStrategyConfiguration
/// @notice Abstract configuration contract for LBPStrategy owner-controlled parameters and breakpoint validation
abstract contract LBPStrategyConfiguration is Ownable, ILBPStrategyConfiguration {
    /// @notice The maximum bracket rate (100% in mps)
    uint24 public constant MAX_BRACKET_RATE = 1e7;
    /// @notice The maximum number of breakpoints
    uint256 public constant MAX_BREAKPOINTS = 3;

    /// @notice The protocol fee controller
    address public protocolFeeController;
    /// @notice The minimum rate that any bracket can have, set by the owner
    uint24 public minBracketRate;

    /// @inheritdoc ILBPStrategyConfiguration
    function setProtocolFeeController(address _protocolFeeController) external onlyOwner {
        _setProtocolFeeController(_protocolFeeController);
        emit ProtocolFeeControllerSet(_protocolFeeController);
    }

    /// @inheritdoc ILBPStrategyConfiguration
    function setMinBracketRate(uint24 _minBracketRate) external onlyOwner {
        _setMinBracketRate(_minBracketRate);
        emit MinBracketRateSet(_minBracketRate);
    }

    /// @notice Sets the min bracket rate
    /// @param _minBracketRate The min bracket rate
    function _setMinBracketRate(uint24 _minBracketRate) internal {
        if (_minBracketRate == 0 || _minBracketRate > MAX_BRACKET_RATE) {
            revert InvalidMinBracketRate(_minBracketRate);
        }
        minBracketRate = _minBracketRate;
    }

    /// @notice Sets the protocol fee controller
    /// @param _protocolFeeController The protocol fee controller
    function _setProtocolFeeController(address _protocolFeeController) internal {
        if (_protocolFeeController == address(0)) {
            revert InvalidProtocolFeeController();
        }
        protocolFeeController = _protocolFeeController;
    }

    /// @notice Validates the breakpoint configuration
    /// @param _breakpoints The breakpoint array defining the bracket schedule
    function _validateBreakpoints(ILBPStrategy.Breakpoint[] memory _breakpoints) internal view {
        uint256 len = _breakpoints.length;
        if (len == 0 || len > MAX_BREAKPOINTS) revert InvalidBreakpointLength(len);

        // First breakpoint must start at 0
        if (_breakpoints[0].lowerThreshold != 0) {
            revert InvalidBreakpointThreshold(_breakpoints[0].lowerThreshold);
        }

        for (uint256 i; i < len; ++i) {
            uint24 rate = _breakpoints[i].rate;
            // Every rate must be within [minBracketRate, MAX_BRACKET_RATE]
            if (rate < minBracketRate || rate > MAX_BRACKET_RATE) {
                revert InvalidBreakpointRate(rate);
            }

            // For non-first breakpoints, lowerThresholds must be strictly ascending
            if (i > 0) {
                uint128 lowerThreshold = _breakpoints[i].lowerThreshold;
                if (lowerThreshold <= _breakpoints[i - 1].lowerThreshold) {
                    revert InvalidBreakpointThreshold(lowerThreshold);
                }
            }
        }
    }
}
