// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {TokenDistribution} from "src/libraries/TokenDistribution.sol";

contract TokenDistributionHelper is Test {
    function calculateTokenSplit(uint128 totalSupply, uint24 tokenSplit) public pure returns (uint128) {
        return TokenDistribution.calculateTokenSplit(totalSupply, tokenSplit);
    }

    function calculateReserveSupply(uint128 totalSupply, uint24 tokenSplit) public pure returns (uint128) {
        return TokenDistribution.calculateReserveSupply(totalSupply, tokenSplit);
    }
}

contract TokenDistributionTest is Test {
    uint256 constant Q192 = 2 ** 192;
    TokenDistributionHelper public tokenDistributionHelper;

    function setUp() public {
        tokenDistributionHelper = new TokenDistributionHelper();
    }

    function test_calculateTokenSplit_succeeds() public view {
        uint128 totalSupply = 1000e18;
        uint24 tokenSplit = 5e6;
        uint128 expectedAuctionSupply = 500e18;
        uint128 auctionSupply = tokenDistributionHelper.calculateTokenSplit(totalSupply, tokenSplit);
        assertEq(auctionSupply, expectedAuctionSupply);

        tokenSplit = 1e7;
        expectedAuctionSupply = 1000e18;
        auctionSupply = tokenDistributionHelper.calculateTokenSplit(totalSupply, tokenSplit);
        assertEq(auctionSupply, expectedAuctionSupply);

        tokenSplit = 0;
        expectedAuctionSupply = 0;
        auctionSupply = tokenDistributionHelper.calculateTokenSplit(totalSupply, tokenSplit);
        assertEq(auctionSupply, expectedAuctionSupply);

        tokenSplit = 2e6;
        expectedAuctionSupply = 200e18;
        auctionSupply = tokenDistributionHelper.calculateTokenSplit(totalSupply, tokenSplit);
        assertEq(auctionSupply, expectedAuctionSupply);
    }

    function test_fuzz_calculateTokenSplit(uint128 totalSupply, uint24 tokenSplit) public view {
        tokenSplit = uint24(bound(tokenSplit, 0, TokenDistribution.MAX_TOKEN_SPLIT));
        assertLe(uint256(totalSupply) * tokenSplit, type(uint256).max); // safe: totalSupply * tokenSplit will never overflow type(uint256).max
        uint128 auctionSupply = tokenDistributionHelper.calculateTokenSplit(totalSupply, tokenSplit);
        assertLe(auctionSupply, totalSupply);
    }

    function test_calculateReserveSupply_succeeds() public view {
        uint128 totalSupply = 1000e18;
        uint24 tokenSplit = 5e6;
        uint128 expectedReserveSupply = 500e18;
        uint128 reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplit);
        assertEq(reserveSupply, expectedReserveSupply);

        tokenSplit = 1e7;
        expectedReserveSupply = 0;
        reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplit);
        assertEq(reserveSupply, expectedReserveSupply);

        tokenSplit = 0;
        expectedReserveSupply = 1000e18;
        reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplit);
        assertEq(reserveSupply, expectedReserveSupply);

        tokenSplit = 2e6;
        expectedReserveSupply = 800e18;
        reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplit);
        assertEq(reserveSupply, expectedReserveSupply);
    }

    function test_fuzz_calculateReserveSupply(uint128 totalSupply, uint24 tokenSplit) public view {
        tokenSplit = uint24(bound(tokenSplit, 0, TokenDistribution.MAX_TOKEN_SPLIT));
        assertLe(uint256(totalSupply) * tokenSplit, type(uint256).max); // safe: totalSupply * tokenSplit will never overflow type(uint256).max
        uint128 reserveSupply = tokenDistributionHelper.calculateReserveSupply(totalSupply, tokenSplit);
        assertLe(reserveSupply, totalSupply);
    }
}
