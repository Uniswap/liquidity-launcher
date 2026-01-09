// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {GovernedLBPStrategy} from "@lbp/strategies/GovernedLBPStrategy.sol";
import {IVirtualERC20} from "../../interfaces/external/IVirtualERC20.sol";
import {MigratorParameters} from "../../types/MigratorParameters.sol";

/// @title VirtualGovernedLBPStrategy
/// @notice Strategy for distributing virtual tokens to a v4 pool requiring governance approval
/// @notice Virtual tokens are ERC20 tokens that wrap an underlying token.
/// @dev A version of this strategy was used in the inagural CCA token sale with the Aztec Network
///      deployed on mainnet: https://etherscan.io/address/0xd53006d1e3110fd319a79aeec4c527a0d265e080
contract VirtualGovernedLBPStrategy is GovernedLBPStrategy {
    /// @notice The address of the underlying token that is being distributed - used in the migrated pool
    address public immutable UNDERLYING_TOKEN;

    constructor(
        address _token,
        uint128 _totalSupply,
        MigratorParameters memory _migratorParams,
        bytes memory _initializerParams,
        IPositionManager _positionManager,
        IPoolManager _poolManager,
        address _governance
    )
        // Underlying strategy
        GovernedLBPStrategy(
            _token, _totalSupply, _migratorParams, _initializerParams, _positionManager, _poolManager, _governance
        )
    {
        UNDERLYING_TOKEN = IVirtualERC20(_token).UNDERLYING_TOKEN_ADDRESS();
    }

    /// @notice Returns the address of the underlying token
    function _getPoolToken() internal view override returns (address) {
        return UNDERLYING_TOKEN;
    }
}
