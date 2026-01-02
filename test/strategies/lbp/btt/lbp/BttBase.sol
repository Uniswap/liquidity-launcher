// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LBPTestHelpers} from "../../helpers/LBPTestHelpers.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";
import {MigratorParameters} from "src/types/MigratorParameters.sol";
import {TokenDistribution} from "src/libraries/TokenDistribution.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "continuous-clearing-auction/test/utils/AuctionStepsBuilder.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuctionFactory.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/src/ContinuousClearingAuctionFactory.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

struct FuzzConstructorParameters {
    address token;
    uint128 totalSupply;
    MigratorParameters migratorParams;
    bytes initializerParameters;
    IPositionManager positionManager;
    IPoolManager poolManager;
}

abstract contract BttBase is LBPTestHelpers {
    using AuctionStepsBuilder for bytes;

    uint256 constant FORK_BLOCK = 23097193;
    address constant TOKEN = 0x1111111111111111111111111111111111111111;
    address constant ERC20_CURRENCY = 0x2222222222222222222222222222222222222222;

    LiquidityLauncher liquidityLauncher;
    ILBPStrategyBase lbp;
    uint256 nextTokenId;
    MockERC20 token;
    MockERC20 erc20Currency;
    IContinuousClearingAuctionFactory initializerFactory;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        liquidityLauncher = new LiquidityLauncher(IAllowanceTransfer(PERMIT2));
        vm.label(address(liquidityLauncher), "liquidityLauncher");

        nextTokenId = IPositionManager(POSITION_MANAGER).nextTokenId();

        token = MockERC20(TOKEN);
        vm.label(TOKEN, "token");
        erc20Currency = MockERC20(ERC20_CURRENCY);
        vm.label(ERC20_CURRENCY, "erc20 currency");

        initializerFactory = IContinuousClearingAuctionFactory(address(new ContinuousClearingAuctionFactory()));
        vm.label(address(initializerFactory), "initializerFactory");
    }

    /// @dev Override with the desired hook address w/ permissions/// @inheritdoc Base
    function _getHookAddress() internal pure virtual returns (address) {
        return
            address(
                uint160(uint256(type(uint160).max) & CLEAR_ALL_HOOK_PERMISSIONS_MASK | Hooks.BEFORE_INITIALIZE_FLAG)
            );
    }

    /// @dev Override with the desired contract name
    function _contractName() internal pure virtual returns (string memory);

    /// @dev Override and return the constructor arguments for the contract
    function _encodeConstructorArgs(FuzzConstructorParameters memory _parameters)
        internal
        virtual
        returns (bytes memory)
    {
        return abi.encode(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.initializerParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    function _deployMockToken(uint128 _totalSupply) internal {
        deployCodeTo("MockERC20", abi.encode("Test Token", "TEST", _totalSupply, address(liquidityLauncher)), TOKEN);
    }

    function _deployMockCurrency(uint128 _totalSupply) internal {
        deployCodeTo(
            "MockERC20", abi.encode("Test Currency", "TEST", _totalSupply, address(liquidityLauncher)), ERC20_CURRENCY
        );
    }

    /// @dev Default to using native currency
    function _toValidConstructorParameters(FuzzConstructorParameters memory _parameters)
        internal
        view
        returns (FuzzConstructorParameters memory)
    {
        return _toValidConstructorParameters(_parameters, true);
    }

    function _toValidConstructorParameters(FuzzConstructorParameters memory _parameters, bool _useNativeCurrency)
        internal
        view
        returns (FuzzConstructorParameters memory)
    {
        _parameters.token = address(token);
        _parameters.totalSupply = uint128(_bound(_parameters.totalSupply, TokenDistribution.MAX_TOKEN_SPLIT, 1e30));
        _parameters.migratorParams = _toValidMigrationParameters(_parameters.migratorParams, _useNativeCurrency);
        _parameters.positionManager = IPositionManager(POSITION_MANAGER); // dont need to fuzz
        _parameters.poolManager = IPoolManager(POOL_MANAGER);
        _parameters.initializerParameters = _validAuctionParameters(_parameters, _useNativeCurrency);
        return _parameters;
    }

    function _toValidMigrationParameters(MigratorParameters memory _mParameters, bool _useNativeCurrency)
        internal
        view
        returns (MigratorParameters memory)
    {
        vm.assume(_mParameters.migrationBlock < type(uint64).max);
        _mParameters.currency = _useNativeCurrency ? address(0) : address(erc20Currency);
        _mParameters.migrationBlock =
            uint64(_bound(_mParameters.migrationBlock, block.number + 2, type(uint64).max - 1));
        _mParameters.sweepBlock =
            uint64(_bound(_mParameters.sweepBlock, _mParameters.migrationBlock + 1, type(uint64).max));
        _mParameters.tokenSplitToAuction =
            uint24(_bound(_mParameters.tokenSplitToAuction, 1, TokenDistribution.MAX_TOKEN_SPLIT - 1));
        _mParameters.poolTickSpacing =
            int24(_bound(_mParameters.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        _mParameters.poolLPFee = uint24(_bound(_mParameters.poolLPFee, 1, LPFeeLibrary.MAX_LP_FEE - 1));
        _mParameters.initializerFactory = address(initializerFactory);
        _mParameters.operator = testOperator;
        _mParameters.maxCurrencyAmountForLP = uint128(_bound(_mParameters.maxCurrencyAmountForLP, 1, type(uint128).max));
        vm.assume(
            _mParameters.positionRecipient != address(0) && _mParameters.positionRecipient != ActionConstants.MSG_SENDER
                && _mParameters.positionRecipient != ActionConstants.ADDRESS_THIS
        );
        return _mParameters;
    }

    function _validAuctionParameters(FuzzConstructorParameters memory _parameters, bool _useNativeCurrency)
        internal
        view
        returns (bytes memory)
    {
        AuctionParameters memory initializerParameters;
        initializerParameters.currency = _useNativeCurrency ? address(0) : address(erc20Currency);
        vm.assume(initializerParameters.currency != _parameters.token);
        initializerParameters.fundsRecipient = ActionConstants.MSG_SENDER;
        initializerParameters.tokensRecipient = tokensRecipient;
        initializerParameters.startBlock = uint64(block.number);
        initializerParameters.endBlock = uint64(
            _bound(
                initializerParameters.endBlock,
                initializerParameters.startBlock + 1,
                _parameters.migratorParams.migrationBlock - 1
            )
        );
        initializerParameters.claimBlock = initializerParameters.endBlock + 1;
        initializerParameters.tickSpacing = 1 << 96;
        initializerParameters.validationHook = address(0);
        initializerParameters.floorPrice = 1 << 96;
        initializerParameters.requiredCurrencyRaised = 0;

        uint64 duration = initializerParameters.endBlock - initializerParameters.startBlock;
        vm.assume(1e7 % uint24(duration) == 0);
        uint24 mpsPerBlock = 1e7 / uint24(duration);
        initializerParameters.auctionStepsData = AuctionStepsBuilder.init().addStep(mpsPerBlock, uint40(duration));
        return abi.encode(initializerParameters);
    }

    /// @dev Deploy a strategy to the hook address
    function _deployStrategy(FuzzConstructorParameters memory _parameters) internal {
        address hookAddress = _getHookAddress();
        deployCodeTo(_contractName(), _encodeConstructorArgs(_parameters), hookAddress);
        lbp = ILBPStrategyBase(payable(hookAddress));
        vm.label(address(lbp), "lbp");
    }
}
