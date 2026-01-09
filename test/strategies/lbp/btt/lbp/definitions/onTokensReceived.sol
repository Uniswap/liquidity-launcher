// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BttBase, FuzzConstructorParameters} from "../BttBase.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {FullRangeLBPStrategyNoValidation} from "test/mocks/FullRangeLBPStrategyNoValidation.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/src/ContinuousClearingAuctionFactory.sol";
import {
    IContinuousClearingAuctionFactory
} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuctionFactory.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {ActionConstants} from "v4-periphery/src/libraries/ActionConstants.sol";
import {AuctionStepsBuilder} from "continuous-clearing-auction/test/utils/AuctionStepsBuilder.sol";
import {ITokenCurrencyStorage} from "continuous-clearing-auction/src/interfaces/ITokenCurrencyStorage.sol";

abstract contract OnTokensReceivedTest is BttBase {
    using AuctionStepsBuilder for bytes;

    function test_WhenTokensReceivedIsLessThanTotalSupply(
        FuzzConstructorParameters memory _parameters,
        uint256 _tokensReceived
    ) public {
        // it reverts with {InvalidAmountReceived}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_tokensReceived < _parameters.totalSupply);

        _deployStrategy(_parameters);

        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), _tokensReceived);

        vm.expectRevert(
            abi.encodeWithSelector(
                IDistributionContract.InvalidAmountReceived.selector, _parameters.totalSupply, _tokensReceived
            )
        );
        lbp.onTokensReceived();
    }

    function test_ValidateInitializerParams_WhenFundsRecipientIsNotTheStrategy(
        FuzzConstructorParameters memory _parameters,
        address _fundsRecipient
    ) public {
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_fundsRecipient != ActionConstants.MSG_SENDER && _fundsRecipient != address(0));

        AuctionParameters memory initializerParameters =
            abi.decode(_parameters.initializerParameters, (AuctionParameters));
        initializerParameters.fundsRecipient = _fundsRecipient;
        _parameters.initializerParameters = abi.encode(initializerParameters);

        vm.expectRevert(
            abi.encodeWithSelector(ILBPStrategyBase.InvalidFundsRecipient.selector, _fundsRecipient, address(lbp))
        );
        lbp.onTokensReceived();
    }

    modifier whenFundsRecipientIsTheStrategy() {
        _;
    }

    function test_WhenAuctionAlreadyCreated(FuzzConstructorParameters memory _parameters) public {
        // it reverts with {AuctionAlreadyCreated}

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        deal(address(token), address(liquidityLauncher), type(uint256).max);
        _deployStrategy(_parameters);

        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), _parameters.totalSupply);

        vm.expectRevert(abi.encodeWithSelector(ILBPStrategyBase.AuctionAlreadyCreated.selector));
        lbp.onTokensReceived();
    }

    function test_ValidateInitializerParams_WhenEndBlockIsGTEMigrationBlock(
        FuzzConstructorParameters memory _parameters,
        uint64 _endBlock
    ) public whenFundsRecipientIsTheStrategy {
        // it reverts with {InvalidEndBlock}
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(
            _endBlock >= _parameters.migratorParams.migrationBlock && _endBlock > 1 && _endBlock < type(uint64).max
        );
        AuctionParameters memory initializerParameters =
            abi.decode(_parameters.initializerParameters, (AuctionParameters));
        initializerParameters.endBlock = _endBlock;
        initializerParameters.claimBlock = _endBlock + 1; // mock claim block
        initializerParameters.startBlock = _endBlock - 1; // mock start block
        initializerParameters.auctionStepsData = AuctionStepsBuilder.init().addStep(1e7, 1); // mock step data
        _parameters.initializerParameters = abi.encode(initializerParameters);

        _deployStrategy(_parameters);
        lbp.onTokensReceived();

        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), _parameters.totalSupply);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.InvalidEndBlock.selector, _endBlock, _parameters.migratorParams.migrationBlock
            )
        );
        lbp.onTokensReceived();
    }

    modifier whenEndBlockIsLTMigrationBlock() {
        _;
    }

    function test_ValidateInitializerParams_WhenCurrencyIsNotTheSameAsTheMigrationCurrency(
        FuzzConstructorParameters memory _parameters,
        address _currency
    ) public whenFundsRecipientIsTheStrategy whenEndBlockIsLTMigrationBlock {
        // it reverts with {InvalidCurrency}
        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        vm.assume(_currency != _parameters.migratorParams.currency && _currency != _parameters.token);
        AuctionParameters memory initializerParameters =
            abi.decode(_parameters.initializerParameters, (AuctionParameters));
        initializerParameters.currency = _currency;
        _parameters.initializerParameters = abi.encode(initializerParameters);

        _deployStrategy(_parameters);

        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), _parameters.totalSupply);

        vm.expectRevert(
            abi.encodeWithSelector(
                ILBPStrategyBase.InvalidCurrency.selector, _currency, _parameters.migratorParams.currency
            )
        );
        lbp.onTokensReceived();
    }

    function test_WhenTokensReceivedGTETotalSupply(
        FuzzConstructorParameters memory _parameters,
        uint256 _tokensReceived
    ) public {
        // it deploys an auction via the factory
        // it emits {InitializerCreated}
        // it sets the auction to the correct address

        _parameters = _toValidConstructorParameters(_parameters);
        _deployMockToken(_parameters.totalSupply);

        deal(address(token), address(liquidityLauncher), type(uint256).max);

        _deployStrategy(_parameters);

        uint128 auctionSupply = _parameters.totalSupply - lbp.reserveTokenAmount();

        address auctionAddress = initializerFactory.getAuctionAddress(
            address(token), auctionSupply, _parameters.initializerParameters, bytes32(0), address(lbp)
        );

        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), _parameters.totalSupply);

        vm.expectEmit(true, true, true, true);
        emit ILBPStrategyBase.InitializerCreated(auctionAddress);
        lbp.onTokensReceived();

        assertEq(address(lbp.initializer()), auctionAddress);
    }
}
