// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ILBPStrategy} from "../../interfaces/ILBPStrategy.sol";
import {ILBPStrategyConfiguration} from "../../interfaces/ILBPStrategyConfiguration.sol";

/// @title LBPStrategyConfiguration
/// @notice Abstract configuration contract for LBPStrategy owner-controlled parameters and breakpoint validation
abstract contract LBPStrategyConfiguration is Ownable, ILBPStrategyConfiguration {
    uint24 constant MAX_BRACKET_RATE = 1e7; // 100% in mps
    uint256 constant MAX_BREAKPOINTS = 3;

    address public protocolFeeController;
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
            revert InvalidMinBracketRate();
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
    /// @param _breakpoints The breakpoint array defining the split curve
    function _validateBreakpoints(ILBPStrategy.Breakpoint[] memory _breakpoints) internal view {
        uint256 len = _breakpoints.length;
        if (len == 0 || len > MAX_BREAKPOINTS) revert InvalidBreakpointLength(len);

        uint128 prevThreshold;
        for (uint256 i; i < len; ++i) {
            uint24 rate = _breakpoints[i].rate;
            // Every rate must be within [minBracketRate, MAX_BRACKET_RATE]
            if (rate < minBracketRate || rate > MAX_BRACKET_RATE) {
                revert InvalidBreakpointRate(rate);
            }

            // For non-last breakpoints, thresholds must be ascending and non-zero
            if (i < len - 1) {
                uint128 threshold = _breakpoints[i].threshold;
                if (threshold == 0 || threshold <= prevThreshold) {
                    revert InvalidBreakpointThreshold(threshold);
                }
                prevThreshold = threshold;
            }
        }
    }
}
