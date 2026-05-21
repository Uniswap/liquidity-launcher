// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {ILBPStrategy} from "src/interfaces/ILBPStrategy.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockLBPInitializer} from "./MockLBPInitializer.sol";

/// @notice Adversarial initializer that reenters `strategy.migrate(self)` from inside `sweepCurrency`.
/// With CEI in place (`reserves[initializer] = 0` set before any external call in migrate), the inner
/// reentrant call must revert with AlreadyConsumed.
contract MockReentrantInitializer is MockLBPInitializer {
    using CurrencyLibrary for Currency;

    ILBPStrategy public immutable strategy;

    bool public reentered;
    bytes public capturedRevertData;

    constructor(
        address _token,
        address _currency,
        uint128 _totalSupply,
        address _tokensRecipient,
        address _fundsRecipient,
        uint64 _startBlock,
        uint64 _endBlock,
        ILBPStrategy _strategy
    ) MockLBPInitializer(_token, _currency, _totalSupply, _tokensRecipient, _fundsRecipient, _startBlock, _endBlock) {
        strategy = _strategy;
    }

    function sweepCurrency() external override {
        sweepCurrencyCalled = true;
        if (!reentered) {
            reentered = true;
            // Attempt reentrant migrate on self and capture the revert reason.
            try strategy.migrate(ILBPInitializer(address(this))) {
                capturedRevertData = hex"";
            } catch (bytes memory reason) {
                capturedRevertData = reason;
            }
        }
        // Honest sweep so the outer migrate's CurrencyRaisedMismatch check passes.
        Currency c = Currency.wrap(currency);
        uint256 balance = c.balanceOfSelf();
        if (balance > 0) {
            c.transfer(msg.sender, balance);
        }
    }
}
