// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILBPStrategyBase} from "../interfaces/ILBPStrategyBase.sol";
import {IProtocolFeeController} from "../interfaces/external/IProtocolFeeController.sol";

/// @title ProtocolFeeOperator
/// @notice EIP1167 contract meant to be set as the `operator` of an LBP strategy
///         to stream a portion of the raised currency to a set protocol fee recipient over time
/// @dev Ensure that `initialize` is called during deployment to prevent misuse
contract ProtocolFeeOperator is Initializable {
    using CurrencyLibrary for Currency;

    /// @notice Emitted when protocol fees are swept
    /// @param currency The currency that was swept
    /// @param amount The amount of currency that was swept
    event ProtocolFeeSwept(address indexed currency, uint256 amount);
    /// @notice Emitted when the contract is initialized
    /// @param recipient The address that was set as the recipient
    event RecipientSet(address indexed recipient);

    /// @notice General error for invalid addresses
    error ProtocolFeeRecipientIsZero();
    error ProtocolFeeControllerAddressIsZero();
    error LBPAddressIsZero();
    error RecipientAddressIsZero();

    /// @notice The maximum protocol fee in basis points. Any returned fee above will be clamped to 10%
    uint24 public constant MAX_PROTOCOL_FEE_BPS = 1_000;
    /// @notice Basis points denominator
    uint24 public constant BPS = 10_000;

    /// @notice The recipient to send protocol fees to. Set on construction as it varies per chain
    address public immutable protocolFeeRecipient;
    /// @notice The controller that will provide the protocol fee in basis points
    IProtocolFeeController public immutable protocolFeeController;

    /// @notice The address to forward the tokens and currency to. Set on initialization
    /// @dev It is crucial that this is set correctly after deployment to the intended address
    address public recipient;
    /// @notice The LBP strategy to sweep the tokens and currency from. Set on initialization
    ILBPStrategyBase public lbp;

    /// @notice Construct the implementation with immutable protocol fee recipient and controller
    constructor(address _protocolFeeRecipient, address _protocolFeeController) {
        if (_protocolFeeRecipient == address(0)) revert ProtocolFeeRecipientIsZero();
        protocolFeeRecipient = _protocolFeeRecipient;
        if (_protocolFeeController == address(0)) revert ProtocolFeeControllerAddressIsZero();
        protocolFeeController = IProtocolFeeController(_protocolFeeController);
        _disableInitializers();
    }

    /// @notice Initializes the contract. MUST be called atomically during deployment to prevent frontrunning.
    /// @param _lbp The LBP strategy to sweep the tokens and currency from
    /// @param _recipient The address to forward the tokens and currency to
    function initialize(address _lbp, address _recipient) external initializer {
        if (_lbp == address(0)) revert LBPAddressIsZero();
        lbp = ILBPStrategyBase(_lbp);
        if (_recipient == address(0)) revert RecipientAddressIsZero();
        recipient = _recipient;

        emit RecipientSet(_recipient);
    }

    /// @notice Sweeps the token from the LBP strategy, forwarding all tokens to the set recipient
    function sweepToken() external {
        Currency token = Currency.wrap(lbp.token());
        lbp.sweepToken();

        token.transfer(recipient, token.balanceOfSelf());
    }

    /// @notice Sweeps the currency from the LBP strategy
    /// @notice Forwards the protocol fee portion to the protocol fee recipient and the remaining to the set recipient
    function sweepCurrency() external {
        Currency currency = Currency.wrap(lbp.currency());

        uint256 currencyBalanceBefore = currency.balanceOfSelf();
        lbp.sweepCurrency();
        uint256 currencyBalanceAfter = currency.balanceOfSelf();
        // Safe to cast since we never raise more than uint128.max
        uint128 currencySwept = uint128(currencyBalanceAfter - currencyBalanceBefore);
        // Get the protocol fee in basis points, clamped to the maximum protocol fee
        uint24 protocolFeeBps = getProtocolFeeBps(Currency.unwrap(currency), currencySwept);

        uint128 feeAmount = (currencySwept * protocolFeeBps) / BPS;

        // Send the protocol fee to the fee tapper
        currency.transfer(protocolFeeRecipient, feeAmount);
        // Send the remaining amount to the recipient
        currency.transfer(recipient, currencySwept - feeAmount);

        emit ProtocolFeeSwept(Currency.unwrap(currency), currencySwept);
    }

    /// @notice Gets the protocol fee in basis points for the given currency
    /// @dev Returns the fee as a uint24, capped at MAX_PROTOCOL_FEE_BPS. Returns 0 if the call reverts for any reason.
    function getProtocolFeeBps(address currency, uint128 amount) public view returns (uint24 protocolFee) {
        (bool success, bytes memory data) = address(protocolFeeController)
            .staticcall(abi.encodeWithSelector(IProtocolFeeController.getProtocolFeeBps.selector, currency, amount));
        if (success && data.length >= 32) {
            // Decode into a uint256 and then clamp to the maximum protocol fee. Safe to cast to uint24 since MAX_PROTOCOL_FEE_BPS fits within a uint24
            protocolFee = uint24(FixedPointMathLib.min(abi.decode(data, (uint256)), MAX_PROTOCOL_FEE_BPS));
        } else {
            // Default to no protocol fee in the event of a revert or malformed return data
            protocolFee = 0;
        }
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}
