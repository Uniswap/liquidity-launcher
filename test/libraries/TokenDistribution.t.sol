// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {TokenDistribution} from "../../src/libraries/TokenDistribution.sol";

contract TokenDistributionHelper is Test {
    function calculateAuctionSupply(uint128 totalSupply, uint24 tokenSplitToAuction)
        public
        pure
        returns (uint128 auctionSupply)
    {
        return TokenDistribution.calculateAuctionSupply(totalSupply, tokenSplitToAuction);
    }

    function calculateReserveSupply(uint128 totalSupply, uint24 tokenSplitToAuction)
        public
        pure
        returns (uint128 reserveSupply)
    {
        return TokenDistribution.calculateReserveSupply(totalSupply, tokenSplitToAuction);
    }
}

contract TokenDistributionTest is Test {
    uint256 constant Q192 = 2 ** 192;
    TokenDistributionHelper public tokenDistributionHelper;

    function setUp() public {
        tokenDistributionHelper = new TokenDistributionHelper();
    }

    function test_calculateAuctionSupply_succeeds() public view {
        uint128 totalSupply = 1000e18;
        uint24 tokenSplitToAuction = 5e6;
        uint128 expectedAuctionSupply = 500e18;
        uint128 auctionSupply = tokenDistributionHelper.calculateAuctionSupply(totalSupply, tokenSplitToAuction);
        assertEq(auctionSupply, expectedAuctionSupply);

        tokenSplitToAuction = 1e7;
        expectedAuctionSupply = 1000e18;
        auctionSupply = tokenDistributionHelper.calculateAuctionSupply(totalSupply, tokenSplitToAuction);
        assertEq(auctionSupply, expectedAuctionSupply);

        tokenSplitToAuction = 0;
        expectedAuctionSupply = 0;
        auctionSupply = tokenDistributionHelper.calculateAuctionSupply(totalSupply, tokenSplitToAuction);
        assertEq(auctionSupply, expectedAuctionSupply);

        tokenSplitToAuction = 2e6;
        expectedAuctionSupply = 200e18;
        auctionSupply = tokenDistributionHelper.calculateAuctionSupply(totalSupply, tokenSplitToAuction);
        assertEq(auctionSupply, expectedAuctionSupply);
    }

    function test_fuzz_calculateAuctionSupply(uint128 totalSupply, uint24 tokenSplitToAuction) public view {
        tokenSplitToAuction = uint24(bound(tokenSplitToAuction, 0, TokenDistribution.MAX_TOKEN_SPLIT));
        assertLe(uint256(totalSupply) * tokenSplitToAuction, type(uint256).max); // safe: totalSupply * tokenSplitToAuction will never overflow type(uint256).max
        uint128 auctionSupply = tokenDistributionHelper.calculateAuctionSupply(totalSupply, tokenSplitToAuction);
        assertLe(auctionSupply, totalSupply);
    }

    function test_calculateReserveSupply_succeeds() public view {
        uint128 totalSupply = 1000e18;
        uint24 tokenSplitToAuction = 5e6;
        uint128 expectedReserveSupply = 500e18;
        uint128 reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplitToAuction);
        assertEq(reserveSupply, expectedReserveSupply);

        tokenSplitToAuction = 1e7;
        expectedReserveSupply = 0;
        reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplitToAuction);
        assertEq(reserveSupply, expectedReserveSupply);

        tokenSplitToAuction = 0;
        expectedReserveSupply = 1000e18;
        reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplitToAuction);
        assertEq(reserveSupply, expectedReserveSupply);

        tokenSplitToAuction = 2e6;
        expectedReserveSupply = 800e18;
        reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplitToAuction);
        assertEq(reserveSupply, expectedReserveSupply);
    }

    function test_fuzz_calculateReserveSupply(uint128 totalSupply, uint24 tokenSplitToAuction) public view {
        tokenSplitToAuction = uint24(bound(tokenSplitToAuction, 0, TokenDistribution.MAX_TOKEN_SPLIT));
        assertLe(uint256(totalSupply) * tokenSplitToAuction, type(uint256).max); // safe: totalSupply * tokenSplitToAuction will never overflow type(uint256).max
        uint128 reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplitToAuction);
        assertLe(reserveSupply, totalSupply);
    }
}
