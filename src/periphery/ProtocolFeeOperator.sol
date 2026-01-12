// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILBPStrategyBase} from "../interfaces/ILBPStrategyBase.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @title ProtocolFeeOperator
/// @notice Deployed instances of this contract are meant to be set as the `operator` of an LBP strategy
///         and they send a portion of the raised currency to the configured protocol fee recipient
/// @dev Ensure that `initialize` is called after deployment to set up ownership
contract ProtocolFeeOperator is Initializable {
    using CurrencyLibrary for Currency;

    /// @notice Emitted when the protocol fee is swept
    /// @param currency The currency that was swept
    /// @param amount The amount of currency that was sent to the protocol fee recipient
    event ProtocolFeeSwept(address indexed currency, uint256 amount);
    /// @notice Emitted when ownership of the contract is transferred
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    /// @notice Thrown when the caller is not the owner
    error NotOwner();

    uint24 public constant PROTOCOL_FEE_BPS = 15;
    uint24 public constant BPS = 10_000;

    /// @notice The address to forward the protocol fees to. Set on construction as it varies per chain
    address public immutable protocolFeeRecipient;
    /// @notice The owner of the contract. Set on initialization
    /// @dev It is crucial that this is set correctly after deployment to the intended address
    address public owner;

    constructor(address _protocolFeeRecipient) {
        protocolFeeRecipient = _protocolFeeRecipient;
        _disableInitializers();
    }

    /// @notice Initializes the contract
    function initialize(address _owner) external initializer {
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    /// @notice Transfers ownership of the contract to a new address
    /// @dev Setting `_newOwner` to the zero address will relinquish ownership
    function transferOwnership(address _newOwner) external onlyOwner {
        owner = _newOwner;
        emit OwnershipTransferred(msg.sender, _newOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Sweeps the token from the LBP strategy, forwarding all tokens to the recipient
    /// @param _lbp The LBP strategy to sweep the token from
    /// @param _recipient The address to forward the tokens to
    function sweepToken(ILBPStrategyBase _lbp, address _recipient) external onlyOwner {
        Currency token = Currency.wrap(_lbp.token());
        _lbp.sweepToken();

        token.transfer(_recipient, token.balanceOfSelf());
    }

    /// @notice Sweeps the currency from the LBP strategy
    /// @notice Forwards the protocol fee portion to the protocol fee recipient and the remaining to the recipient
    /// @param _lbp The LBP strategy to sweep the currency from
    /// @param _recipient The address to forward the currency to
    function sweepCurrency(ILBPStrategyBase _lbp, address _recipient) external onlyOwner {
        Currency currency = Currency.wrap(_lbp.currency());
        uint256 currencyBalanceBefore = currency.balanceOfSelf();
        _lbp.sweepCurrency();
        uint256 currencyBalanceAfter = currency.balanceOfSelf();
        uint256 currencySwept = currencyBalanceAfter - currencyBalanceBefore;
        // Calculate the fee, rounding down
        uint256 fee = currencySwept * PROTOCOL_FEE_BPS / BPS;

        currency.transfer(protocolFeeRecipient, fee);
        currency.transfer(_recipient, currencySwept - fee);
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}
