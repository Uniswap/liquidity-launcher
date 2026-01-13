// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ILBPStrategyBase} from "../interfaces/ILBPStrategyBase.sol";
import {IProtocolFeeController} from "../interfaces/external/IProtocolFeeController.sol";

/// @title ProtocolFeeOperator
/// @notice EIP1167 Contract meant to be set as the `operator` of an LBP strategy
///         to send a portion of the raised currency to a set protocol fee recipient
/// @dev Ensure that `initialize` is called during deployment to prevent misuse
contract ProtocolFeeOperator is Initializable {
    using CurrencyLibrary for Currency;

    /// @notice Emitted when the protocol fee is swept
    /// @param currency The currency that was swept
    /// @param amount The amount of currency that was sent to the protocol fee recipient
    event ProtocolFeeReleased(address indexed currency, uint256 amount);
    /// @notice Emitted when the contract is initialized
    event RecipientSet(address indexed recipient);

    /// @notice General error for invalid addresses
    error InvalidAddress();

    /// @notice The maximum protocol fee in basis points. Any returned fee above will be clamped to this value
    uint24 public constant MAX_PROTOCOL_FEE_BPS = 100;
    uint24 public constant BPS = 10_000;
    uint24 public constant BPS_RELEASED_PER_BLOCK = 100;

    /// @notice The address to forward the protocol fees to. Set on construction as it varies per chain
    address public immutable protocolFeeRecipient;
    /// @notice The controller that will provide the protocol fee in basis points
    IProtocolFeeController public immutable protocolFeeController;

    /// @notice The address to forward the tokens and currency to. Set on initialization
    /// @dev It is crucial that this is set correctly after deployment to the intended address
    address public recipient;
    /// @notice The LBP strategy to sweep the tokens and currency from. Set on initialization
    ILBPStrategyBase public lbp;
    /// @notice Cumulative index of accrued protocol fees
    uint256 public index;
    /// @notice The block number of the last release of fees
    uint256 public lastReleaseBlock;

    /// @notice Construct the implementation with immutable protocol fee recipient and controller
    constructor(address _protocolFeeRecipient, address _protocolFeeController) {
        protocolFeeRecipient = _protocolFeeRecipient;
        if (_protocolFeeController == address(0)) revert InvalidAddress();
        protocolFeeController = IProtocolFeeController(_protocolFeeController);
        _disableInitializers();
    }

    /// @notice Initializes the contract. MUST be called during deployment.
    function initialize(address _lbp, address _recipient) external initializer {
        if (_lbp == address(0)) revert InvalidAddress();
        lbp = ILBPStrategyBase(_lbp);
        recipient = _recipient;
        lastReleaseBlock = block.number;

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
        // settle any existing fees
        _release(currency);

        uint256 currencyBalanceBefore = currency.balanceOfSelf();
        lbp.sweepCurrency();
        uint256 currencyBalanceAfter = currency.balanceOfSelf();
        uint256 currencySwept = currencyBalanceAfter - currencyBalanceBefore;
        // Get the protocol fee in basis points, clamped to the maximum protocol fee
        uint24 protocolFee = uint24(
            FixedPointMathLib.min(
                protocolFeeController.getProtocolFeeBps(Currency.unwrap(currency), currencySwept), MAX_PROTOCOL_FEE_BPS
            )
        );

        index += currencySwept * protocolFee;
        currency.transfer(recipient, currencySwept * (BPS - protocolFee) / BPS);
    }

    /// @notice Releases currency to the protocol fee recipient
    function _release(Currency currency) internal {
        uint256 _index = index;
        if (_index == 0) {
            lastReleaseBlock = block.number;
            return;
        }
        uint256 elapsed = block.number - lastReleaseBlock;
        if (elapsed == 0) return;

        uint256 delta = FixedPointMathLib.fullMulDiv(_index, elapsed * BPS_RELEASED_PER_BLOCK, BPS);
        if (delta > _index) delta = _index;

        index -= delta;
        lastReleaseBlock = block.number;

        // since the division by BPS was deferred in `sweepCurrency`, divide here and round down
        uint256 toRelease = delta / BPS;
        if (toRelease > 0) {
            currency.transfer(protocolFeeRecipient, toRelease);
            emit ProtocolFeeReleased(Currency.unwrap(currency), toRelease);
        }
    }

    /// @notice Releases any accrued protocol fees to the protocol fee recipient
    function release() external {
        _release(Currency.wrap(lbp.currency()));
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}
