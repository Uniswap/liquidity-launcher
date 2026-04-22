// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ILBPStrategy} from "../../interfaces/ILBPStrategy.sol";
import {ILBPStrategyConfiguration} from "../../interfaces/ILBPStrategyConfiguration.sol";

/// @title LBPStrategyConfiguration
/// @notice Abstract configuration contract for LBPStrategy owner-controlled parameters and breakpoint validation
abstract contract LBPStrategyConfiguration is Ownable, ILBPStrategyConfiguration {
    uint24 constant MAX_BRACKET_RATE = 1e7; // 100% in mps
    uint256 constant MAX_BREAKPOINTS = 10;

    address public protocolFeeController;
    uint24 public minSplitForLp;

    /// @inheritdoc ILBPStrategyConfiguration
    function setProtocolFeeController(address _protocolFeeController) external onlyOwner {
        _setProtocolFeeController(_protocolFeeController);
        emit ProtocolFeeControllerSet(_protocolFeeController);
    }

    /// @inheritdoc ILBPStrategyConfiguration
    function setMinSplitForLp(uint24 _minSplitForLp) external onlyOwner {
        _setMinSplitForLp(_minSplitForLp);
        emit MinSplitForLpSet(_minSplitForLp);
    }

    /// @notice Sets the min split for LP
    /// @param _minSplitForLp The min split for LP
    function _setMinSplitForLp(uint24 _minSplitForLp) internal {
        if (_minSplitForLp == 0 || _minSplitForLp > MAX_BRACKET_RATE) {
            revert InvalidMinSplitForLp();
        }
        minSplitForLp = _minSplitForLp;
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
        if (len == 0 || len > MAX_BREAKPOINTS) revert InvalidBreakpointConfiguration();

        uint128 prevThreshold;
        for (uint256 i; i < len; ++i) {
            uint24 rate = _breakpoints[i].rate;
            // Every rate must be within [minSplitForLp, MAX_BRACKET_RATE]
            if (rate < minSplitForLp || rate > MAX_BRACKET_RATE) {
                revert InvalidBreakpointConfiguration();
            }

            // For non-last breakpoints, thresholds must be ascending and non-zero
            if (i < len - 1) {
                uint128 threshold = _breakpoints[i].threshold;
                if (threshold == 0 || (i > 0 && threshold <= prevThreshold)) {
                    revert InvalidBreakpointConfiguration();
                }
                prevThreshold = threshold;
            }
        }
    }
}
