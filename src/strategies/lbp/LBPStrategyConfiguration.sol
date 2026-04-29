// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "solady/auth/Ownable.sol";
import {ILBPStrategyConfiguration} from "../../interfaces/ILBPStrategyConfiguration.sol";

/// @title LBPStrategyConfiguration
/// @notice Abstract configuration contract for LBPStrategy owner-controlled parameters
abstract contract LBPStrategyConfiguration is Ownable, ILBPStrategyConfiguration {
    /// @notice The protocol fee controller
    address public protocolFeeController;
    /// @notice The min split for LP
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
        if (_minSplitForLp == 0 || _minSplitForLp > 10_000) {
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
}
