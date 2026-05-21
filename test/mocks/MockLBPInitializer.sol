// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    ILBPInitializer,
    LBPInitializationParams,
    ILBP_INITIALIZER_INTERFACE_ID
} from "src/interfaces/ILBPInitializer.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Configurable mock initializer for testing LBPStrategy
contract MockLBPInitializer is ILBPInitializer {
    using CurrencyLibrary for Currency;

    address public token;
    address public currency;
    uint128 public totalSupply;
    address public tokensRecipient;
    address public fundsRecipient;
    uint64 public startBlock;
    uint64 public endBlock;

    LBPInitializationParams public storedLbpParams;

    bool public sweepCurrencyCalled;
    bool public sweepUnsoldTokensCalled;

    constructor(
        address _token,
        address _currency,
        uint128 _totalSupply,
        address _tokensRecipient,
        address _fundsRecipient,
        uint64 _startBlock,
        uint64 _endBlock
    ) {
        token = _token;
        currency = _currency;
        totalSupply = _totalSupply;
        tokensRecipient = _tokensRecipient;
        fundsRecipient = _fundsRecipient;
        startBlock = _startBlock;
        endBlock = _endBlock;
    }

    function setLbpInitializationParams(LBPInitializationParams memory _params) external {
        storedLbpParams = _params;
    }

    /// @notice Test-only mutator: lets a test flip the declared token after registration to
    /// exercise the strategy's defense against malicious initializers lying about their own properties.
    function setToken(address _token) external {
        token = _token;
    }

    /// @notice Test-only mutator: lets a test flip the declared currency after registration.
    function setCurrency(address _currency) external {
        currency = _currency;
    }

    function lbpInitializationParams() external view returns (LBPInitializationParams memory) {
        return storedLbpParams;
    }

    function sweepCurrency() external virtual {
        sweepCurrencyCalled = true;
        // Transfer all currency held by this contract to the caller (the strategy)
        Currency c = Currency.wrap(currency);
        uint256 balance = c.balanceOfSelf();
        if (balance > 0) {
            c.transfer(msg.sender, balance);
        }
    }

    function sweepUnsoldTokens() external {
        sweepUnsoldTokensCalled = true;
        // Transfer all tokens held by this contract to the caller (the strategy)
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).transfer(msg.sender, balance);
        }
    }

    function onTokensReceived() external {}

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == ILBP_INITIALIZER_INTERFACE_ID || interfaceId == type(IERC165).interfaceId;
    }

    receive() external payable {}
}
