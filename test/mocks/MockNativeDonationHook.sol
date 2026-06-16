// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {InitializerHook} from "src/periphery/hooks/InitializerHook.sol";

/// @notice Test-only InitializerHook that donates a fixed amount of native currency to the
/// `modifyLiquidities` caller (the LBPStrategy) during `afterAddLiquidity`.
/// @dev The donation is realized by settling native ETH the hook holds (crediting the hook), then
/// returning the matching negative hook delta. v4-core negates the hook delta onto the caller's
/// delta, so the strategy ends the unlock owed `donationAmount` of native currency. The position
/// plan's closing `TAKE_PAIR` then returns that amount to the strategy as POSM "dust". This lets a
/// test drive the path where nonzero native dust is captured by the strategy and force-sent to the recipient.
contract MockNativeDonationHook is InitializerHook {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    /// @notice Native currency donated to the caller, paid out once across the whole plan.
    uint256 public immutable donationAmount;
    /// @notice Guards the donation to a single `afterAddLiquidity` call so the returned dust is
    /// deterministic regardless of how many positions the plan mints.
    bool public donated;

    constructor(IPoolManager _poolManager, address _authorized, uint256 _donationAmount)
        InitializerHook(_poolManager, _authorized)
    {
        donationAmount = _donationAmount;
    }

    /// @inheritdoc InitializerHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory perms) {
        // beforeInitialize gates pool creation to `authorized` (inherited from InitializerHook); the
        // afterAddLiquidity + return-delta flags let the hook hand a native credit to the caller.
        perms.beforeInitialize = true;
        perms.afterAddLiquidity = true;
        perms.afterAddLiquidityReturnDelta = true;
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        if (donated || donationAmount == 0) {
            return (IHooks.afterAddLiquidity.selector, toBalanceDelta(0, 0));
        }
        donated = true;

        // Pay the donation as native currency, crediting this hook. Sync first to force native settling.
        poolManager.sync(CurrencyLibrary.ADDRESS_ZERO);
        poolManager.settle{value: donationAmount}();

        // Owe the credit back to the caller: v4-core negates this hook delta onto the caller's delta,
        // leaving the strategy owed `donationAmount` of native currency (collected by TAKE_PAIR).
        int128 owed = -donationAmount.toInt128();
        BalanceDelta hookDelta =
            key.currency0.isAddressZero() ? toBalanceDelta(owed, int128(0)) : toBalanceDelta(int128(0), owed);

        return (IHooks.afterAddLiquidity.selector, hookDelta);
    }

    receive() external payable {}
}
