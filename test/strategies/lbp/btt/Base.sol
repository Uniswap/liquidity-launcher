// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LBPTestHelpers} from "../helpers/LBPTestHelpers.sol";
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

struct FuzzConstructorParameters {
    address token;
    uint128 totalSupply;
    MigratorParameters migratorParams;
    bytes auctionParameters;
    IPositionManager positionManager;
    IPoolManager poolManager;
}

abstract contract Base is LBPTestHelpers {
    using AuctionStepsBuilder for bytes;

    uint256 constant FORK_BLOCK = 23097193;

    LiquidityLauncher liquidityLauncher;
    ILBPStrategyBase lbp;
    uint256 nextTokenId;
    MockERC20 token;

    /// @dev Override with the desired hook address w/ permissions
    function _getHookAddress() internal virtual returns (address);

    function _toValidConstructorParameters(FuzzConstructorParameters memory _parameters)
        internal
        view
        returns (FuzzConstructorParameters memory)
    {
        _parameters.token = address(token);
        _parameters.totalSupply =
            uint128(_bound(_parameters.totalSupply, TokenDistribution.MAX_TOKEN_SPLIT, type(uint128).max));
        _parameters.migratorParams = _toValidMigrationParameters(_parameters.migratorParams);
        _parameters.positionManager = IPositionManager(POSITION_MANAGER); // dont need to fuzz
        _parameters.poolManager = IPoolManager(POOL_MANAGER);
        _parameters.auctionParameters = _validAuctionParameters(_parameters);
        return _parameters;
    }

    function _toValidMigrationParameters(MigratorParameters memory _mParameters)
        internal
        view
        returns (MigratorParameters memory)
    {
        vm.assume(_mParameters.migrationBlock < type(uint64).max);
        _mParameters.migrationBlock =
            uint64(_bound(_mParameters.migrationBlock, block.number + 1, type(uint64).max - 1));
        _mParameters.sweepBlock =
            uint64(_bound(_mParameters.sweepBlock, _mParameters.migrationBlock + 1, type(uint64).max));
        _mParameters.tokenSplitToAuction =
            uint24(_bound(_mParameters.tokenSplitToAuction, 1, TokenDistribution.MAX_TOKEN_SPLIT - 1));
        _mParameters.poolTickSpacing =
            int24(_bound(_mParameters.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        _mParameters.poolLPFee = uint24(_bound(_mParameters.poolLPFee, 1, LPFeeLibrary.MAX_LP_FEE - 1));
        vm.assume(
            _mParameters.positionRecipient != address(0) && _mParameters.positionRecipient != ActionConstants.MSG_SENDER
                && _mParameters.positionRecipient != ActionConstants.ADDRESS_THIS
        );
        return _mParameters;
    }

    function _validAuctionParameters(FuzzConstructorParameters memory _parameters)
        internal
        view
        returns (bytes memory)
    {
        AuctionParameters memory auctionParameters;
        auctionParameters.currency = _parameters.migratorParams.currency;
        auctionParameters.fundsRecipient = ActionConstants.MSG_SENDER;
        auctionParameters.startBlock = uint64(block.number);
        auctionParameters.endBlock =
            uint64(_bound(auctionParameters.endBlock, block.number, _parameters.migratorParams.migrationBlock - 1));
        auctionParameters.claimBlock = auctionParameters.endBlock + 1;
        auctionParameters.tickSpacing = 1 << 96;
        auctionParameters.validationHook = address(0);
        auctionParameters.floorPrice = 1 << 96;
        auctionParameters.requiredCurrencyRaised = 0;
        auctionParameters.auctionStepsData = AuctionStepsBuilder.init().addStep(100e3, 50).addStep(100e3, 50);
        return abi.encode(auctionParameters);
    }

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"), FORK_BLOCK);
        liquidityLauncher = new LiquidityLauncher(IAllowanceTransfer(PERMIT2));
        nextTokenId = IPositionManager(POSITION_MANAGER).nextTokenId();
    }

    function _deployMockToken(uint128 _totalSupply) internal {
        token = new MockERC20("Test Token", "TEST", _totalSupply, address(liquidityLauncher));
    }

    /// @dev Deploy a strategy with the given bytecode
    function _deployStrategy(bytes memory bytecode) internal {
        address hookAddress = _getHookAddress();
        vm.etch(hookAddress, bytecode);
        lbp = ILBPStrategyBase(payable(hookAddress));
        vm.label(address(lbp), "lbp");
    }
}
