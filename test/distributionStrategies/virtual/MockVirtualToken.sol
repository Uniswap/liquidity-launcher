
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import {IATPFactory} from "@atp/ATPFactory.sol";
import {RevokableParams} from "@atp/atps/linear/ILATP.sol";
import {LockLib} from "@atp/libraries/LockLib.sol";
import {Ownable} from "@oz/access/Ownable.sol";
import {ERC20} from "@oz/token/ERC20/ERC20.sol";
import {IERC20} from "@oz/token/ERC20/IERC20.sol";
import {IAuction} from "@twap-auction/interfaces/IAuction.sol";

interface IVirtualToken is IERC20 {
    function UNDERLYING_TOKEN_ADDRESS() external view returns (IERC20);
}

interface IAztecVirtualToken is IVirtualToken {
    event AuctionAddressSet(IAuction auctionAddress);
    event StrategyAddressSet(address strategyAddress);
    event UnderlyingTokensRecovered(address to, uint256 amount);

    // event TransferedFromAuction(address to, uint256 amount);

    error VirtualAztecToken__ZeroAddress();
    error VirtualAztecToken__Recover__InvalidAddress();
    error VirtualAztecToken__UnderlyingTokensNotBacked();
    error VirtualAztecToken__NotImplemented();
    error VirtualAztecToken__AuctionNotSet();
    error VirtualAztecToken__StrategyNotSet();

    function mint(address _to, uint256 _amount) external;
    function setAuctionAddress(IAuction _auctionAddress) external;
    function setStrategyAddress(address _strategyAddress) external;

    function auctionAddress() external view returns (IAuction);
    function strategyAddress() external view returns (address);
    function ATP_FACTORY_LOW_AMOUNTS() external view returns (IATPFactory);
    function ATP_FACTORY_STAKE_AMOUNTS() external view returns (IATPFactory);
}

/**
 * @title Virtual Aztec Token
 * @author Aztec-Labs
 * @notice The virtual aztec token is a token used to represent the aztec token within the auction system.
 *         It is expected to hold its entire supply
 */
contract VirtualAztecToken is ERC20, Ownable, IAztecVirtualToken {
    /// @notice If purchasing over the stake amount - they go into a must stake ATP
    uint256 public constant MIN_STAKE_AMOUNT = 200_000 ether;

    /// @notice The address of the underlying token - the aztec token
    IERC20 public immutable UNDERLYING_TOKEN_ADDRESS;

    /// @notice The address of the ATP factory contract for when not purchasing over the stake amount
    IATPFactory public immutable ATP_FACTORY_LOW_AMOUNTS;

    /// @notice The address of the ATP factory contract for when purchasing over the stake amount
    IATPFactory public immutable ATP_FACTORY_STAKE_AMOUNTS;

    /// @notice The address of the foundation
    address public immutable FOUNDATION_ADDRESS;

    /// @notice The address of the TWAP auction contract
    IAuction internal $auctionAddress;
    /// @notice The address of the launcher strategy contract
    address internal $strategyAddress;

    constructor(IERC20 _underlyingTokenAddress, IATPFactory _atpFactoryLowAmounts, IATPFactory _atpFactoryStakeAmounts, address _foundationAddress)
        ERC20("Virtual-AZTEC", "VAZT")
        Ownable(msg.sender)
    {
        require(address(_underlyingTokenAddress) != address(0), VirtualAztecToken__ZeroAddress());
        require(address(_atpFactoryLowAmounts) != address(0), VirtualAztecToken__ZeroAddress());
        require(address(_atpFactoryStakeAmounts) != address(0), VirtualAztecToken__ZeroAddress());
        require(address(_foundationAddress) != address(0), VirtualAztecToken__ZeroAddress());

        UNDERLYING_TOKEN_ADDRESS = _underlyingTokenAddress;
        ATP_FACTORY_LOW_AMOUNTS = _atpFactoryLowAmounts;
        ATP_FACTORY_STAKE_AMOUNTS = _atpFactoryStakeAmounts;
        FOUNDATION_ADDRESS = _foundationAddress;
    }

    /**
     * @notice Mint the tokens to the recipient
     * @param _to The address of the recipient
     * @param _amount The amount of tokens to mint
     * @dev Only callable by the owner
     * @dev the minter must have approved the virtual tokens contract to spend the underlying token
     * @dev the minting must be backed 1 to 1 by the underlying tokens
     */
    function mint(address _to, uint256 _amount) external override(IAztecVirtualToken) onlyOwner {
        IERC20(UNDERLYING_TOKEN_ADDRESS).transferFrom(msg.sender, address(this), _amount);

        // Check that the underlying tokens are backed 1 to 1 by the virtual tokens
        // The total supply of this token + the amount to mint should be less than or equal to the balance of the underlying held
        uint256 totalSupply = totalSupply();
        uint256 underlyingBalance = IERC20(UNDERLYING_TOKEN_ADDRESS).balanceOf(address(this));
        require(totalSupply + _amount <= underlyingBalance, VirtualAztecToken__UnderlyingTokensNotBacked());

        // Mint the tokens
        _mint(_to, _amount);
    }

    function setAuctionAddress(IAuction _auctionAddress) external override(IAztecVirtualToken) onlyOwner {
        require(address(_auctionAddress) != address(0), VirtualAztecToken__ZeroAddress());

        $auctionAddress = _auctionAddress;
        emit AuctionAddressSet(_auctionAddress);
    }

    function setStrategyAddress(address _strategyAddress) external override(IAztecVirtualToken) onlyOwner {
        require(_strategyAddress != address(0), VirtualAztecToken__ZeroAddress());

        $strategyAddress = _strategyAddress;
        emit StrategyAddressSet(_strategyAddress);
    }
 
    function auctionAddress() external view override(IAztecVirtualToken) returns (IAuction) {
        return $auctionAddress;
    }

    function strategyAddress() external view override(IAztecVirtualToken) returns (address) {
        return $strategyAddress;
    }

    /**
     * @notice Transfer the token to the recipient
     * @param _to The address of the recipient
     * @param _amount The amount of tokens to transfer
     * @return bool Whether the transfer was successful
     *
     * @dev Only implements token transfers if the sender is the auction contract or the pool migrator contract
     */
    // TODO: ensure that there are no circumstances where this can burn more tokens than are expected
    function transfer(address _to, uint256 _amount) public override(ERC20, IERC20) returns (bool) {
        require(address($auctionAddress) != address(0), VirtualAztecToken__AuctionNotSet());
        require(address($strategyAddress) != address(0), VirtualAztecToken__StrategyNotSet());
        
        
        if (msg.sender == address($auctionAddress) && _to == FOUNDATION_ADDRESS) {
            // Burn the virtual tokens
            _burn(msg.sender, _amount);

            // Transfer the underlying tokens back to the foundation
            return IERC20(UNDERLYING_TOKEN_ADDRESS).transfer(_to, _amount);
        }
        // If the transfer is being made from the auction contract, it will mint an ATP for the recipient
        else if (msg.sender == address($auctionAddress)) {
            // Burn the virtual tokens
            _burn(msg.sender, _amount);

            // Create the ATP
            _mintAtp(_to, _amount);
            // emit TransferedFromAuction(_to, _amount);
            return true;
        }
        // If the transfer is being made from the pool migrator contract, it will transfer the underlying tokens
        // The migrator will move the virtual tokens into the auction system at the beginning of the auction
        // So we need to check that the auction has ended in order to transfer the underlying tokens - for migration
        // be done by asserting the address it is sending to is NOT the auction address
        else if (msg.sender == $strategyAddress && _to != address($auctionAddress)) {
            // Burn the virtual tokens
            _burn(msg.sender, _amount);

            // Transfer the underlying tokens to the pool migrator
            return IERC20(UNDERLYING_TOKEN_ADDRESS).transfer(_to, _amount);
        }

        // Otherwise, transfer the tokens normally
        return super.transfer(_to, _amount);
    }

    /**
     * @notice Transfer the tokens from the sender to the recipient
     * param from The address of the sender
     * param to The address of the recipient
     * param amount The amount of tokens to transfer
     * @return bool Whether the transfer was successful
     * @dev Reverts as transfer from is not implemented
     */
    function transferFrom(address, /*from*/ address, /*to*/ uint256 /*amount*/ )
        public
        pure
        override(ERC20, IERC20)
        returns (bool)
    {
        revert VirtualAztecToken__NotImplemented();
    }

    /**
     * @notice Mint the ATP
     * @param _beneficiary The address of the beneficiary
     * @param _amount The amount of tokens to mint into the ATP
     * @dev Creates a MATP if the amount is greater than or equal to the min stake amount, otherwise creates a LATP
     */
    function _mintAtp(address _beneficiary, uint256 _amount) internal {
        if (_amount >= MIN_STAKE_AMOUNT) {
            // Transfer the underlying tokens to the ATP factory
            IERC20(UNDERLYING_TOKEN_ADDRESS).transfer(address(ATP_FACTORY_STAKE_AMOUNTS), _amount);
            ATP_FACTORY_STAKE_AMOUNTS.createLATP(
                _beneficiary, _amount, RevokableParams({revokeBeneficiary: address(0), lockParams: LockLib.empty()})
            );
        } else {
            // Transfer the underlying tokens to the ATP factory
            IERC20(UNDERLYING_TOKEN_ADDRESS).transfer(address(ATP_FACTORY_LOW_AMOUNTS), _amount);
            ATP_FACTORY_LOW_AMOUNTS.createLATP(
                _beneficiary, _amount, RevokableParams({revokeBeneficiary: address(0), lockParams: LockLib.empty()})
            );
        }
    }
}
