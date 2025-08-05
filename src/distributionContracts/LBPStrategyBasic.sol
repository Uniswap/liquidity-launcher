// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {IDistributionContract} from "../interfaces/IDistributionContract.sol";
import {MigratorParameters} from "../types/MigratorParams.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Planner} from "../libraries/Planner.sol";
import {Plan} from "../types/Plan.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ILBPStrategyBasic} from "../interfaces/ILBPStrategyBasic.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDistributionStrategy} from "../interfaces/IDistributionStrategy.sol";
import {HookBasic} from "../utils/HookBasic.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LBPStrategyBasic
/// @notice Basic Strategy to distribute tokens and raise funds from an auction to a v4 pool
contract LBPStrategyBasic is ILBPStrategyBasic, HookBasic {
    using CustomRevert for bytes4;
    using SafeERC20 for IERC20;
    using Planner for Plan;

    /// @notice The token split is measured in bips (10000 = 100%)
    uint16 public constant MAX_TOKEN_SPLIT = 10000;

    address public immutable tokenAddress;
    address public immutable currency;

    uint256 public immutable totalSupply;
    address public immutable positionRecipient;
    uint64 public immutable migrationBlock;
    address public immutable auctionFactory;
    uint16 public immutable tokenSplit;

    IPositionManager public immutable positionManager;

    bytes public auctionParameters;
    uint256 public initialTokenAmount;
    uint256 public initialCurrencyAmount;
    uint160 public initialSqrtPriceX96; // currency1 / currency0
    address public auction;
    PoolKey public key;

    /// @notice Initializes the LBPStrategyBasic contract and creates the auction contract
    /// @param _tokenAddress The token to distribute
    /// @param _totalSupply The total supply of the token
    /// @param _configData The configuration data for the LBPStrategyBasic contract
    constructor(address _tokenAddress, uint256 _totalSupply, bytes memory _configData) HookBasic(_configData) {
        (MigratorParameters memory migratorParams, bytes memory auctionParams) =
            abi.decode(_configData, (MigratorParameters, bytes));

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

        // initialize pool with starting price
        positionManager.initializePool(key, initialSqrtPriceX96);

        Plan memory planner = Planner.init();

        if (key.currency0 == Currency.wrap(currency)) {
            planner.add(Actions.SETTLE, abi.encode(key.currency0, initialCurrencyAmount, true));
            planner.add(Actions.SETTLE, abi.encode(key.currency1, initialTokenAmount, true));
        } else {
            planner.add(Actions.SETTLE, abi.encode(key.currency0, initialTokenAmount, true));
            planner.add(Actions.SETTLE, abi.encode(key.currency1, initialCurrencyAmount, true));
        }
        planner.add(
            Actions.MINT_POSITION_FROM_DELTAS,
            abi.encode(
                key,
                TickMath.MIN_TICK,
                TickMath.MAX_TICK,
                type(uint128).max,
                type(uint128).max,
                positionRecipient,
                Constants.ZERO_BYTES
            )
        );

        bytes memory plan = planner.encode();

        positionManager.modifyLiquidities(plan, block.timestamp + 1);

        emit PoolInitialized(key, initialSqrtPriceX96);
    }

    /// @inheritdoc IDistributionContract
    function onTokensReceived(address token, uint256 amount) external {
        if (token != address(tokenAddress)) InvalidToken.selector.revertWith();
        if (amount != totalSupply) IncorrectTokenSupply.selector.revertWith();
        if (IERC20(token).balanceOf(address(this)) != amount) InvalidAmountReceived.selector.revertWith();

        uint256 auctionSupply = amount * tokenSplit / MAX_TOKEN_SPLIT;

        auction = address(
            IDistributionStrategy(auctionFactory).initializeDistribution(tokenAddress, auctionSupply, auctionParameters)
        );

        IERC20(token).safeTransfer(auction, auctionSupply);
        IDistributionContract(auction).onTokensReceived(tokenAddress, auctionSupply);
    }

    /// @inheritdoc ILBPStrategyBasic
    /// @dev The sqrt price will be opposite the auction price if the currency address is less than the token address
    function setInitialPrice(uint160 sqrtPriceX96, uint256 tokenAmount, uint256 currencyAmount) public payable {
        if (msg.sender != auction) OnlyAuctionCanSetPrice.selector.revertWith();
        if (Currency.wrap(currency).isAddressZero()) {
            if (msg.value != tokenAmount) InvalidCurrencyAmount.selector.revertWith();
        } else {
            IERC20(currency).safeTransferFrom(msg.sender, address(this), currencyAmount);
        }
        initialSqrtPriceX96 = sqrtPriceX96;
        initialTokenAmount = tokenAmount;
        initialCurrencyAmount = currencyAmount;

        emit InitialPriceSet(sqrtPriceX96, tokenAmount, currencyAmount);
    }
}
