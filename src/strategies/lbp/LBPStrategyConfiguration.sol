// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ILBPStrategy} from "../../interfaces/ILBPStrategy.sol";
import {ILBPStrategyConfiguration} from "../../interfaces/ILBPStrategyConfiguration.sol";

/// @title LBPStrategyConfiguration
/// @notice Abstract configuration contract for LBPStrategy owner-controlled parameters and bracket validation
abstract contract LBPStrategyConfiguration is Ownable, ILBPStrategyConfiguration {
    /// @notice The maximum bracket rate (100% in mps)
    uint24 public constant MAX_BRACKET_RATE = 1e7;
    /// @notice The maximum number of brackets in the LP allocation schedule
    uint256 public constant MAX_BRACKETS = 3;

    /// @notice The protocol fee controller
    address public protocolFeeController;

    /// @inheritdoc ILBPStrategyConfiguration
    function setProtocolFeeController(address _protocolFeeController) external onlyOwner {
        _setProtocolFeeController(_protocolFeeController);
        emit ProtocolFeeControllerSet(_protocolFeeController);
    }

    /// @notice Sets the protocol fee controller
    /// @param _protocolFeeController The protocol fee controller
    function _setProtocolFeeController(address _protocolFeeController) internal {
        if (_protocolFeeController == address(0)) {
            revert InvalidProtocolFeeController();
        }
        protocolFeeController = _protocolFeeController;
    }

    /// @notice Validates an abi-encoded LP allocation schedule
    /// @dev The schedule is an abi-encoded LpAllocationBracket[]. It must contain 1 to MAX_BRACKETS brackets,
    /// with the first bracket's lowerThreshold = 0, all rates in [0, MAX_BRACKET_RATE], and strictly ascending
    /// lowerThresholds.
    /// @param _schedule The abi-encoded LP allocation schedule
    function _validateLpAllocationSchedule(bytes memory _schedule) internal pure {
        ILBPStrategy.LpAllocationBracket[] memory brackets = abi.decode(_schedule, (ILBPStrategy.LpAllocationBracket[]));
        uint256 count = brackets.length;
        if (count == 0 || count > MAX_BRACKETS) revert InvalidBracketCount(count);

        uint256 prevLower;
        for (uint256 i = 0; i < count; i++) {
            uint256 lowerThreshold = brackets[i].lowerThreshold;
            uint24 rate = brackets[i].rate;
            if (rate > MAX_BRACKET_RATE) revert InvalidBracketRate(rate);
            if (i == 0 && lowerThreshold != 0) revert InvalidBracketThreshold(lowerThreshold);
            if (i > 0 && lowerThreshold <= prevLower) revert InvalidBracketThreshold(lowerThreshold);
            prevLower = lowerThreshold;
        }
    }
}
