// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Recipient that reverts on any native currency transfer. A plain `currency.transfer`
/// to this contract reverts; a force-send (SELFDESTRUCT) still delivers the ETH.
contract MockRejectEth {
    error EthRejected();

    receive() external payable {
        revert EthRejected();
    }
}
