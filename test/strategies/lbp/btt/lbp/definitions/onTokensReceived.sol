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

abstract contract OnTokensReceivedTest is BttBase {
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
        vm.assume(_tokensReceived >= _parameters.totalSupply);

        _deployStrategy(_parameters);

        uint128 auctionSupply = _parameters.totalSupply - lbp.reserveSupply();

        address auctionAddress = initializerFactory.getAuctionAddress(
            address(token), auctionSupply, _parameters.initializerParameters, bytes32(0), address(lbp)
        );

        vm.prank(address(liquidityLauncher));
        token.transfer(address(lbp), _tokensReceived);

        vm.expectEmit(true, true, true, true);
        emit ILBPStrategyBase.InitializerCreated(auctionAddress);
        lbp.onTokensReceived();

        assertEq(address(lbp.initializer()), auctionAddress);
    }
}
