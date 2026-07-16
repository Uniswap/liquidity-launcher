// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IDynamicFeeModule} from "../../src/interfaces/IDynamicFeeModule.sol";

/// @notice Module that returns configurable fees for both directions
contract MockDynamicFeeModule is IDynamicFeeModule {
    uint24 public zeroForOneFee;
    uint24 public oneForZeroFee;

    function setFees(uint24 _zeroForOneFee, uint24 _oneForZeroFee) external {
        zeroForOneFee = _zeroForOneFee;
        oneForZeroFee = _oneForZeroFee;
    }

    function getFee(PoolKey calldata) external view returns (uint24, uint24) {
        return (zeroForOneFee, oneForZeroFee);
    }
}

/// @notice Module that always reverts
contract MockRevertingDynamicFeeModule is IDynamicFeeModule {
    error ModuleBroken();

    function getFee(PoolKey calldata) external pure returns (uint24, uint24) {
        revert ModuleBroken();
    }
}

/// @notice Module that returns malformed data shorter than the expected return encoding
contract MockGarbageDynamicFeeModule {
    fallback() external {
        assembly {
            return(0, 8)
        }
    }
}
