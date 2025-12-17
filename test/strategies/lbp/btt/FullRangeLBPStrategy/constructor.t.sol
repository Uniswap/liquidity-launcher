// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttBase} from "./BttBase.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";
import {FuzzConstructorParameters} from "../Base.sol";
import {FullRangeLBPStrategyNoValidation} from "test/mocks/FullRangeLBPStrategyNoValidation.sol";
import {TokenDistribution} from "src/libraries/TokenDistribution.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";

contract ConstructorTest is BttBase {
    function test_WhenSweepBlockIsLTEMigrationBlock(
        FuzzConstructorParameters memory _parameters,
        uint64 _sweepBlock,
        uint64 _migrationBlock
    ) public {
        // it reverts with {InvalidSweepBlock}
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_sweepBlock <= _migrationBlock);
        _parameters.migratorParams.sweepBlock = _sweepBlock;
        _parameters.migratorParams.migrationBlock = _migrationBlock;

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.InvalidSweepBlock.selector, _sweepBlock, _migrationBlock)
        );
        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    modifier whenSweepBlockIsGTMigrationBlock() {
        _;
    }

    function test_WhenTokenSplitToAuctionIsGTEMaxTokenSplit(
        FuzzConstructorParameters memory _parameters,
        uint24 _tokenSplitToAuction
    ) public whenSweepBlockIsGTMigrationBlock {
        // it reverts with {TokenSplitTooHigh}
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_tokenSplitToAuction >= TokenDistribution.MAX_TOKEN_SPLIT);
        _parameters.migratorParams.tokenSplitToAuction = _tokenSplitToAuction;

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.TokenSplitTooHigh.selector, _tokenSplitToAuction, TokenDistribution.MAX_TOKEN_SPLIT
            )
        );
        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    modifier whenTokenSplitToAuctionIsLTMaxTokenSplit() {
        _;
    }

    function test_WhenPoolTickSpacingIsGTMaxTickSpacingOrLTMinTickSpacing(
        FuzzConstructorParameters memory _parameters,
        int24 _poolTickSpacing
    ) public whenSweepBlockIsGTMigrationBlock whenTokenSplitToAuctionIsLTMaxTokenSplit {
        // it reverts with {InvalidTickSpacing}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_poolTickSpacing > TickMath.MAX_TICK_SPACING || _poolTickSpacing < TickMath.MIN_TICK_SPACING);
        _parameters.migratorParams.poolTickSpacing = _poolTickSpacing;

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.InvalidTickSpacing.selector,
                _poolTickSpacing,
                TickMath.MIN_TICK_SPACING,
                TickMath.MAX_TICK_SPACING
            )
        );
        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    modifier whenPoolTickSpacingIsWithinMinMaxTickSpacing() {
        _;
    }

    function test_WhenPoolLPFeeIsGTFeeMax(FuzzConstructorParameters memory _parameters, uint24 _poolLPFee)
        public
        whenSweepBlockIsGTMigrationBlock
        whenTokenSplitToAuctionIsLTMaxTokenSplit
        whenPoolTickSpacingIsWithinMinMaxTickSpacing
    {
        // it reverts with {InvalidFee}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        _poolLPFee = uint24(_bound(_poolLPFee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));
        _parameters.migratorParams.poolLPFee = _poolLPFee;

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.InvalidFee.selector, _poolLPFee, LPFeeLibrary.MAX_LP_FEE)
        );
        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    modifier whenPoolLPFeeIsLTEMaxLPFee() {
        _;
    }

    function test_WhenPositionRecipientIsAReservedAddress(
        FuzzConstructorParameters memory _parameters,
        address _positionRecipient,
        uint256 _seed
    )
        public
        whenSweepBlockIsGTMigrationBlock
        whenTokenSplitToAuctionIsLTMaxTokenSplit
        whenPoolTickSpacingIsWithinMinMaxTickSpacing
        whenPoolLPFeeIsLTEMaxLPFee
    {
        // it reverts with {InvalidPositionRecipient}
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        if (_seed % 3 == 0) {
            _positionRecipient = address(0);
        } else if (_seed % 3 == 1) {
            _positionRecipient = ActionConstants.MSG_SENDER;
        } else {
            _positionRecipient = ActionConstants.ADDRESS_THIS;
        }

        _parameters.migratorParams.positionRecipient = _positionRecipient;

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBase.InvalidPositionRecipient.selector, _positionRecipient));
        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    modifier whenPositionRecipientIsNotAReservedAddress() {
        _;
    }

    function test_WhenAuctionSupplyIsZero(FuzzConstructorParameters memory _parameters)
        public
        whenSweepBlockIsGTMigrationBlock
        whenTokenSplitToAuctionIsLTMaxTokenSplit
        whenPoolTickSpacingIsWithinMinMaxTickSpacing
        whenPoolLPFeeIsLTEMaxLPFee
        whenPositionRecipientIsNotAReservedAddress
    {
        // it reverts with {AuctionSupplyIsZero}
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        // happens when total supply * tokenSplitToAuction < 1e7
        _parameters.totalSupply = uint128(_bound(_parameters.totalSupply, 1, TokenDistribution.MAX_TOKEN_SPLIT - 1));
        _parameters.migratorParams.tokenSplitToAuction =
            uint24(_bound(_parameters.migratorParams.tokenSplitToAuction, 1, TokenDistribution.MAX_TOKEN_SPLIT - 1));
        vm.assume(
            _parameters.totalSupply * _parameters.migratorParams.tokenSplitToAuction < TokenDistribution.MAX_TOKEN_SPLIT
        );

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBase.AuctionSupplyIsZero.selector));
        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    modifier whenAuctionSupplyIsNotZero() {
        _;
    }

    modifier whenMigrationParametersAreValid() {
        _;
    }

    /**************************************************
     *               _validateAuctionParams
     **************************************************/

    function test_WhenFundsRecipientIsNotMSG_SENDER(
        FuzzConstructorParameters memory _parameters,
        address _fundsRecipient
    ) public whenAuctionSupplyIsNotZero whenMigrationParametersAreValid {
        // it reverts with {InvalidFundsRecipient}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_fundsRecipient != ActionConstants.MSG_SENDER);

        AuctionParameters memory auctionParameters = abi.decode(_parameters.auctionParameters, (AuctionParameters));
        auctionParameters.fundsRecipient = _fundsRecipient;
        _parameters.auctionParameters = abi.encode(auctionParameters);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.InvalidFundsRecipient.selector, _fundsRecipient, ActionConstants.MSG_SENDER
            )
        );
        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    modifier whenFundsRecipientIsMSG_SENDER() {
        _;
    }

    function test_WhenEndBlockIsGTEMigrationBlock(FuzzConstructorParameters memory _parameters, uint64 _endBlock)
        public
        whenAuctionSupplyIsNotZero
        whenMigrationParametersAreValid
        whenFundsRecipientIsMSG_SENDER
    {
        // it reverts with {InvalidEndBlock}
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_endBlock >= _parameters.migratorParams.migrationBlock);
        AuctionParameters memory auctionParameters = abi.decode(_parameters.auctionParameters, (AuctionParameters));
        auctionParameters.endBlock = _endBlock;
        _parameters.auctionParameters = abi.encode(auctionParameters);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.InvalidEndBlock.selector, _endBlock, _parameters.migratorParams.migrationBlock
            )
        );
        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    modifier whenEndBlockIsLTMigrationBlock() {
        _;
    }

    function test_WhenCurrencyIsNotTheSameAsTheMigrationCurrency(
        FuzzConstructorParameters memory _parameters,
        address _currency
    )
        public
        whenAuctionSupplyIsNotZero
        whenMigrationParametersAreValid
        whenFundsRecipientIsMSG_SENDER
        whenEndBlockIsLTMigrationBlock
    {
        // it reverts with {InvalidCurrency}
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_currency != _parameters.migratorParams.currency);
        AuctionParameters memory auctionParameters = abi.decode(_parameters.auctionParameters, (AuctionParameters));
        auctionParameters.currency = _currency;
        _parameters.auctionParameters = abi.encode(auctionParameters);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.InvalidCurrency.selector, _currency, _parameters.migratorParams.currency
            )
        );
        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }

    modifier whenCurrencyIsTheSameAsTheMigrationCurrency() {
        _;
    }

    function test_CanBeConstructed(FuzzConstructorParameters memory _parameters)
        public
        whenAuctionSupplyIsNotZero
        whenMigrationParametersAreValid
        whenFundsRecipientIsMSG_SENDER
        whenEndBlockIsLTMigrationBlock
        whenCurrencyIsTheSameAsTheMigrationCurrency
    {
        // it does not revert

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        new FullRangeLBPStrategyNoValidation(
            _parameters.token,
            _parameters.totalSupply,
            _parameters.migratorParams,
            _parameters.auctionParameters,
            _parameters.positionManager,
            _parameters.poolManager
        );
    }
}
