// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract LBPStrategy_CurrencySplit_Test is LBPStrategyTestBase {
    function test_currencySplit_50percent() public pure {
        assertEq(_currencyAmountForLp(100e18, 5e6), 50e18);
    }

    function test_currencySplit_100percent() public pure {
        assertEq(_currencyAmountForLp(100e18, 1e7), 100e18);
    }

    function test_currencySplit_1percent() public pure {
        assertEq(_currencyAmountForLp(100e18, 1e5), 1e18);
    }

    function test_currencySplit_truncation() public pure {
        assertEq(_currencyAmountForLp(10e18, 3_333_333), 10e18 * 3_333_333 / 1e7);
    }

    function _currencyAmountForLp(uint256 currencyAmount, uint24 split) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(currencyAmount, split, 1e7);
    }

    function test_fuzz_currencySplitNeverExceedsRaised(uint256 raised, uint24 split) public pure {
        split = uint24(bound(split, 1, 1e7));
        raised = bound(raised, 0, type(uint128).max);

        uint256 result = _currencyAmountForLp(raised, split);
        assertLe(result, raised);

        if (split == 1e7) {
            assertEq(result, raised);
        }
    }
}
