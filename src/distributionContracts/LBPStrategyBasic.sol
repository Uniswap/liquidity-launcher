// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {HookBasic} from "../utils/HookBasic.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using CustomRevert for bytes4;
    using SafeERC20 for IERC20;

    /// @notice The token split is measured in bips (10_000 = 100%)
    uint16 public constant MAX_TOKEN_SPLIT = 10_000;

    address public immutable tokenAddress;
    address public immutable currency;

    uint256 public immutable totalSupply;
    address public immutable positionRecipient;
    uint64 public immutable migrationBlock;
    address public immutable auctionFactory;
    uint16 public immutable tokenSplit;

    IPositionManager public immutable positionManager;
    IDistributionContract public auction;

    bytes public auctionParameters;
    uint256 public initialTokenAmount;
    uint256 public initialCurrencyAmount;
    uint160 public initialSqrtPriceX96; // expressed as currency1/currency0
    PoolKey public key;

    /// @notice Initializes the LBPStrategyBasic contract and creates the auction contract
    /// @param _tokenAddress The token to distribute
    /// @param _totalSupply The total supply of the token
    /// @param _configData The configuration data for the LBPStrategyBasic contract
    constructor(address _tokenAddress, uint256 _totalSupply, bytes memory _configData) HookBasic(_configData) {
        (MigratorParameters memory migratorParams, bytes memory auctionParams) =
            abi.decode(_configData, (MigratorParameters, bytes));

        // validate token split is less than or equal to 50%
        if (migratorParams.tokenSplit > 5000) TokenSplitTooHigh.selector.revertWith();

        auctionParameters = auctionParams;

        tokenAddress = _tokenAddress;
        currency = migratorParams.currency;
        totalSupply = _totalSupply;
        positionManager = IPositionManager(migratorParams.positionManager);
        positionRecipient = migratorParams.positionRecipient;
        migrationBlock = migratorParams.migrationBlock;
        auctionFactory = migratorParams.auctionFactory;
        tokenSplit = migratorParams.tokenSplit;

        key = PoolKey({
            currency0: currency < tokenAddress ? Currency.wrap(currency) : Currency.wrap(tokenAddress),
            currency1: currency < tokenAddress ? Currency.wrap(tokenAddress) : Currency.wrap(currency),
            fee: migratorParams.fee,
            tickSpacing: migratorParams.tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    /// @inheritdoc ILBPStrategyBasic
    function migrate() public {
        if (block.number < migrationBlock) MigrationNotAllowed.selector.revertWith();

        // transfer tokens to the position manager
        IERC20(tokenAddress).safeTransfer(address(positionManager), initialTokenAmount);

        // transfer raised currency to the position manager if currency is not ETH
        if (!Currency.wrap(currency).isAddressZero()) {
            IERC20(currency).safeTransfer(address(positionManager), initialCurrencyAmount);
        }

        // initialize pool with starting price
        // fails if already initialized or if the price is not set / is 0 (MIN_SQRT_PRICE is 4295128739)
        poolManager.initialize(key, initialSqrtPriceX96);

        bytes memory plan = _createPlan();

        // if currency is ETH, we need to send ETH to the position manager
        if (Currency.wrap(currency).isAddressZero()) {
            positionManager.modifyLiquidities{value: initialCurrencyAmount}(plan, block.timestamp + 1);
        } else {
            positionManager.modifyLiquidities(plan, block.timestamp + 1);
        }

        emit Migrated(key, initialSqrtPriceX96);
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived(address token, uint256 amount) external {
        if (token != address(tokenAddress)) InvalidToken.selector.revertWith();
        if (amount != totalSupply) IncorrectTokenSupply.selector.revertWith();
        if (IERC20(token).balanceOf(address(this)) != amount) InvalidAmountReceived.selector.revertWith();

        uint256 auctionSupply = amount * tokenSplit / MAX_TOKEN_SPLIT;

        auction = IDistributionStrategy(auctionFactory).initializeDistribution(
            tokenAddress, auctionSupply, auctionParameters, bytes32(0)
        );

        IERC20(token).safeTransfer(address(auction), auctionSupply);
        auction.onTokensReceived(tokenAddress, auctionSupply);
    }

    /// @inheritdoc ILBPStrategyBasic
    /// @dev The sqrt price is always expressed as currency1/currency0, where currency0 < currency1
    function setInitialPrice(uint160 sqrtPriceX96, uint256 tokenAmount, uint256 currencyAmount) public payable {
        if (msg.sender != address(auction)) OnlyAuctionCanSetPrice.selector.revertWith();
        if (Currency.wrap(currency).isAddressZero()) {
            if (msg.value != currencyAmount) InvalidCurrencyAmount.selector.revertWith();
        } else {
            if (msg.value != 0) NonETHCurrencyCannotReceiveETH.selector.revertWith();
            IERC20(currency).safeTransferFrom(msg.sender, address(this), currencyAmount);
        }
        initialSqrtPriceX96 = sqrtPriceX96;
        initialTokenAmount = tokenAmount;
        initialCurrencyAmount = currencyAmount;

        emit InitialPriceSet(sqrtPriceX96, tokenAmount, currencyAmount);
    }

    /// @notice Creates the plan for the position manager to mint the full range position
    /// @return The plan for the position manager
    function _createPlan() internal view returns (bytes memory) {
        bytes memory actions;
        bytes[] memory params = new bytes[](3);

        actions =
            abi.encodePacked(uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.MINT_POSITION_FROM_DELTAS));

        if (key.currency0 == Currency.wrap(currency)) {
            params[0] = abi.encode(key.currency0, initialCurrencyAmount, false);
            params[1] = abi.encode(key.currency1, initialTokenAmount, false);
        } else {
            params[0] = abi.encode(key.currency0, initialTokenAmount, false);
            params[1] = abi.encode(key.currency1, initialCurrencyAmount, false);
        }

        params[2] = abi.encode(
            key,
            TickMath.MIN_TICK,
            TickMath.MAX_TICK,
            type(uint128).max,
            type(uint128).max,
            positionRecipient,
            Constants.ZERO_BYTES
        );

        return abi.encode(actions, params);
    }
}
