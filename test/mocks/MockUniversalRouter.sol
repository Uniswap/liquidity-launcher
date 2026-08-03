// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IUniversalRouter} from "../../src/interfaces/external/IUniversalRouter.sol";

/// @title MockUniversalRouter
/// @notice Stands in for the Universal Router in launcher tests: runs one exact-input v4 buy and, like the
///         real router, credits swap output to the route's recipient rather than the immediate caller.
contract MockUniversalRouter is IUniversalRouter, IUnlockCallback {
    IPoolManager public immutable poolManager;

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    receive() external payable {}

    /// @inheritdoc IUniversalRouter
    /// @dev `inputs[0]` is `(PoolKey key, uint256 nativeIn, address payToken, uint256 payAmount, address
    ///      recipient)`. Unspent native is swept to `recipient`, as a real route's SWEEP would.
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256) external payable override {
        require(commands.length == 1 && uint8(commands[0]) == 0x10, "unsupported route");
        (PoolKey memory key, uint256 nativeIn, address payToken, uint256 payAmount, address recipient) =
            abi.decode(inputs[0], (PoolKey, uint256, address, uint256, address));

        if (payToken == address(0)) {
            require(nativeIn != 0, "nothing to spend");
            poolManager.unlock(abi.encode(key, nativeIn, recipient));
        } else {
            require(IERC20(payToken).balanceOf(address(this)) >= payAmount, "route not funded");
            IERC20(payToken).transfer(msg.sender, payAmount / 2);
        }

        if (address(this).balance != 0) CurrencyLibrary.ADDRESS_ZERO.transfer(recipient, address(this).balance);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "not pool manager");
        (PoolKey memory key, uint256 amountIn, address recipient) = abi.decode(data, (PoolKey, uint256, address));

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        poolManager.sync(CurrencyLibrary.ADDRESS_ZERO);
        poolManager.settle{value: uint256(uint128(-delta.amount0()))}();
        poolManager.take(key.currency1, recipient, uint256(uint128(delta.amount1())));

        return "";
    }
}
