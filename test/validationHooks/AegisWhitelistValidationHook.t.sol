// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {AegisWhitelistValidationHook} from "../../src/validationHooks/AegisWhitelistValidationHook.sol";
import {ContinuousClearingAuction} from "continuous-clearing-auction/src/ContinuousClearingAuction.sol";
import {AuctionParameters} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {AuctionStepsBuilder} from "continuous-clearing-auction/test/utils/AuctionStepsBuilder.sol";
import {ValidationHookLib} from "continuous-clearing-auction/src/libraries/ValidationHookLib.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {MerkleTreeLib} from "@solady/src/utils/MerkleTreeLib.sol";

contract AegisWhitelistValidationHookTest is Test {
    using AuctionStepsBuilder for bytes;

    uint128 private constant TOTAL_SUPPLY = 1_000e18;
    uint256 private constant FLOOR_PRICE = 1000 << FixedPoint96.RESOLUTION;
    uint256 private constant TICK_SPACING = 100 << FixedPoint96.RESOLUTION;
    uint256 private constant TIER_SIZE = 50;

    address private alice;
    address private bob;
    address private carol;

    AegisWhitelistValidationHook private hook;
    ContinuousClearingAuction private auction;
    MockERC20 private token;
    bytes32[] private tierOneTree;
    bytes32[] private tierTwoTree;
    bytes32[] private tierThreeTree;

    function setUp() public {
        alice = _tierAccount(1, 0);
        bob = _tierAccount(2, 0);
        carol = _tierAccount(3, 0);

        (bytes32[] memory treeOne, bytes32 rootTierOne) = _buildTierTree(1);
        (bytes32[] memory treeTwo, bytes32 rootTierTwo) = _buildTierTree(2);
        (bytes32[] memory treeThree, bytes32 rootTierThree) = _buildTierTree(3);
        tierOneTree = treeOne;
        tierTwoTree = treeTwo;
        tierThreeTree = treeThree;
        hook = new AegisWhitelistValidationHook(rootTierOne, rootTierTwo, rootTierThree, 2 ether, 10 ether, 50 ether);

        bytes memory steps = AuctionStepsBuilder.init().addStep(100e3, 50).addStep(100e3, 50);
        AuctionParameters memory params = AuctionParameters({
            currency: address(0),
            tokensRecipient: makeAddr("tokensRecipient"),
            fundsRecipient: makeAddr("fundsRecipient"),
            startBlock: uint64(block.number),
            endBlock: uint64(block.number + 100),
            claimBlock: uint64(block.number + 110),
            tickSpacing: TICK_SPACING,
            validationHook: address(hook),
            floorPrice: FLOOR_PRICE,
            requiredCurrencyRaised: 0,
            auctionStepsData: steps
        });

        token = new MockERC20("Test Token", "TEST", TOTAL_SUPPLY, address(this));
        auction = new ContinuousClearingAuction(address(token), TOTAL_SUPPLY, params);
        token.transfer(address(auction), TOTAL_SUPPLY);
        auction.onTokensReceived();
    }

    function test_submitBid_withTierOneProof_succeeds() public {
        // Valid tier-1 member can bid within cap using a correct proof.
        bytes32[] memory proof = MerkleTreeLib.leafProof(tierOneTree, 0);
        bytes memory hookData = abi.encode(uint8(1), proof);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        uint256 bidId = auction.submitBid{value: 2 ether}(FLOOR_PRICE + TICK_SPACING, 2 ether, alice, hookData);

        assertEq(bidId, 0);
        assertEq(hook.committed(alice), 2 ether);
        assertEq(hook.assignedTier(alice), 1);
    }

    function test_submitBid_withTierTwoProof_succeeds() public {
        // Valid tier-2 member can bid within cap using a correct proof.
        bytes32[] memory proof = MerkleTreeLib.leafProof(tierTwoTree, 0);
        bytes memory hookData = abi.encode(uint8(2), proof);
        vm.deal(bob, 5 ether);
        vm.prank(bob);
        uint256 bidId = auction.submitBid{value: 4 ether}(FLOOR_PRICE + TICK_SPACING, 4 ether, bob, hookData);

        assertEq(bidId, 0);
        assertEq(hook.committed(bob), 4 ether);
        assertEq(hook.assignedTier(bob), 2);
    }

    function test_submitBid_withTierThreeProof_succeeds() public {
        // Valid tier-3 member can bid within cap using a correct proof.
        bytes32[] memory proof = MerkleTreeLib.leafProof(tierThreeTree, 0);
        bytes memory hookData = abi.encode(uint8(3), proof);
        vm.deal(carol, 12 ether);
        vm.prank(carol);
        uint256 bidId = auction.submitBid{value: 8 ether}(FLOOR_PRICE + TICK_SPACING, 8 ether, carol, hookData);

        assertEq(bidId, 0);
        assertEq(hook.committed(carol), 8 ether);
        assertEq(hook.assignedTier(carol), 3);
    }

    function test_submitBid_bidIdStartsAtZeroAndIncrements() public {
        // Bid ids are assigned sequentially starting at zero.
        bytes32[] memory proofOne = MerkleTreeLib.leafProof(tierOneTree, 0);
        bytes memory hookDataOne = abi.encode(uint8(1), proofOne);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        uint256 firstBidId = auction.submitBid{value: 1 ether}(FLOOR_PRICE + TICK_SPACING, 1 ether, alice, hookDataOne);
        assertEq(firstBidId, 0);

        bytes32[] memory proofTwo = MerkleTreeLib.leafProof(tierTwoTree, 0);
        bytes memory hookDataTwo = abi.encode(uint8(2), proofTwo);
        vm.deal(bob, 3 ether);
        vm.prank(bob);
        uint256 secondBidId = auction.submitBid{value: 1 ether}(FLOOR_PRICE + TICK_SPACING, 1 ether, bob, hookDataTwo);
        assertEq(secondBidId, 1);
    }

    function test_submitBid_manualWhitelistBypassesProof() public {
        // Manually whitelisted addresses can bid without a valid proof.
        address outsider = _tierAccount(1, TIER_SIZE);
        hook.setManualWhitelist(1, outsider, true);
        bytes32[] memory proof = MerkleTreeLib.leafProof(tierOneTree, 0);
        bytes memory hookData = abi.encode(uint8(1), proof);
        vm.deal(outsider, 2 ether);
        vm.prank(outsider);
        uint256 bidId = auction.submitBid{value: 1 ether}(FLOOR_PRICE + TICK_SPACING, 1 ether, outsider, hookData);

        assertEq(bidId, 0);
        assertEq(hook.committed(outsider), 1 ether);
        assertEq(hook.assignedTier(outsider), 1);
    }

    function test_submitBid_exceedsTierCap_reverts() public {
        // Tier cap is enforced across multiple bids for the same address.
        bytes32[] memory proof = MerkleTreeLib.leafProof(tierOneTree, 0);
        bytes memory hookData = abi.encode(uint8(1), proof);
        vm.deal(alice, 4 ether);
        vm.prank(alice);
        auction.submitBid{value: 2 ether}(FLOOR_PRICE + TICK_SPACING, 2 ether, alice, hookData);

        vm.prank(alice);
        vm.expectRevert();
        auction.submitBid{value: 1 ether}(FLOOR_PRICE + TICK_SPACING, 1 ether, alice, hookData);
    }

    function test_submitBid_afterAllocFilled_reverts() public {
        // Re-entering after fully committing a tier allocation should fail.
        bytes32[] memory proof = MerkleTreeLib.leafProof(tierOneTree, 0);
        bytes memory hookData = abi.encode(uint8(1), proof);
        vm.deal(alice, 3 ether);
        vm.prank(alice);
        auction.submitBid{value: 2 ether}(FLOOR_PRICE + TICK_SPACING, 2 ether, alice, hookData);

        vm.prank(alice);
        vm.expectRevert();
        auction.submitBid{value: 0.1 ether}(FLOOR_PRICE + TICK_SPACING, 0.1 ether, alice, hookData);
    }

    function test_submitBid_notInTree_reverts() public {
        // Address not present in the tier tree is rejected even with a proof.
        address outsider = _tierAccount(1, TIER_SIZE);
        bytes32[] memory proof = MerkleTreeLib.leafProof(tierOneTree, 0);
        bytes memory hookData = abi.encode(uint8(1), proof);
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        vm.expectRevert();
        auction.submitBid{value: 1 ether}(FLOOR_PRICE + TICK_SPACING, 1 ether, outsider, hookData);
    }

    function test_submitBid_wrongTierProof_reverts() public {
        // Using a proof from a different tier should fail validation.
        bytes32[] memory proof = MerkleTreeLib.leafProof(tierTwoTree, 0);
        bytes memory hookData = abi.encode(uint8(1), proof);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert();
        auction.submitBid{value: 1 ether}(FLOOR_PRICE + TICK_SPACING, 1 ether, bob, hookData);
    }

    function _leaf(address account) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }

    function _tierAccount(uint8 tier, uint256 index) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(tier, index)))));
    }

    function _buildTierTree(uint8 tier) private pure returns (bytes32[] memory tree, bytes32 root) {
        bytes32[] memory leaves = new bytes32[](TIER_SIZE);
        for (uint256 i = 0; i < TIER_SIZE; i++) {
            leaves[i] = _leaf(_tierAccount(tier, i));
        }
        tree = MerkleTreeLib.build(leaves);
        root = MerkleTreeLib.root(tree);
    }
}
