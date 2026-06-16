// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenSplitter} from "../../src/strategies/TokenSplitter.sol";
import {ITokenSplitter} from "../../src/interfaces/ITokenSplitter.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";

contract TokenSplitterTest is Test {
    TokenSplitter internal splitter;

    function setUp() public {
        splitter = new TokenSplitter();
    }

    /// @dev Helper: deploy a token to this contract and approve the splitter to pull `amount`.
    function _deployAndApprove(uint256 amount) internal returns (MockERC20 token) {
        token = new MockERC20("Test Token", "TEST", amount, address(this));
        token.approve(address(splitter), amount);
    }

    function test_splitsAcrossRecipients() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](3);
        splits[0] = ITokenSplitter.Split({recipient: alice, amount: 100});
        splits[1] = ITokenSplitter.Split({recipient: bob, amount: 250});
        splits[2] = ITokenSplitter.Split({recipient: carol, amount: 650});

        uint256 totalSupply = 1000;
        MockERC20 token = _deployAndApprove(totalSupply);

        vm.expectEmit(true, false, false, true, address(splitter));
        emit ITokenSplitter.TokensSplit(address(token), totalSupply, 3);
        splitter.initializeDistribution(address(token), totalSupply, abi.encode(splits), bytes32(0));

        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(bob), 250);
        assertEq(token.balanceOf(carol), 650);
        // Strategy never custodies funds, and the allowance is fully consumed.
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.allowance(address(this), address(splitter)), 0);
    }

    function test_singleRecipient() public {
        address alice = makeAddr("alice");
        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](1);
        splits[0] = ITokenSplitter.Split({recipient: alice, amount: 1000});

        MockERC20 token = _deployAndApprove(1000);
        splitter.initializeDistribution(address(token), 1000, abi.encode(splits), bytes32(0));

        assertEq(token.balanceOf(alice), 1000);
    }

    function test_revertsOnNoSplits() public {
        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](0);
        MockERC20 token = _deployAndApprove(1000);

        vm.expectRevert(ITokenSplitter.NoSplits.selector);
        splitter.initializeDistribution(address(token), 1000, abi.encode(splits), bytes32(0));
    }

    function test_revertsOnZeroRecipient() public {
        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](1);
        splits[0] = ITokenSplitter.Split({recipient: address(0), amount: 1000});
        MockERC20 token = _deployAndApprove(1000);

        vm.expectRevert(ITokenSplitter.ZeroRecipient.selector);
        splitter.initializeDistribution(address(token), 1000, abi.encode(splits), bytes32(0));
    }

    function test_revertsOnZeroAmount() public {
        address alice = makeAddr("alice");
        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](1);
        splits[0] = ITokenSplitter.Split({recipient: alice, amount: 0});
        MockERC20 token = _deployAndApprove(1000);

        vm.expectRevert(ITokenSplitter.ZeroAmount.selector);
        splitter.initializeDistribution(address(token), 1000, abi.encode(splits), bytes32(0));
    }

    function test_revertsWhenSumLessThanTotalSupply() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](2);
        splits[0] = ITokenSplitter.Split({recipient: alice, amount: 100});
        splits[1] = ITokenSplitter.Split({recipient: bob, amount: 200});

        MockERC20 token = _deployAndApprove(1000);

        vm.expectRevert(abi.encodeWithSelector(ITokenSplitter.InvalidSplit.selector, 300, 1000));
        splitter.initializeDistribution(address(token), 1000, abi.encode(splits), bytes32(0));
    }

    function test_revertsWhenSumGreaterThanTotalSupply() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](2);
        splits[0] = ITokenSplitter.Split({recipient: alice, amount: 600});
        splits[1] = ITokenSplitter.Split({recipient: bob, amount: 600});

        // Approve the full sum so the transfers don't fail on allowance; the InvalidSplit check must catch it.
        MockERC20 token = new MockERC20("Test Token", "TEST", 1200, address(this));
        token.approve(address(splitter), 1200);

        vm.expectRevert(abi.encodeWithSelector(ITokenSplitter.InvalidSplit.selector, 1200, 1000));
        splitter.initializeDistribution(address(token), 1000, abi.encode(splits), bytes32(0));
    }

    function testFuzz_splitsArbitraryRecipients(uint256[10] memory rawAmounts, uint8 rawCount) public {
        uint256 count = bound(rawCount, 1, 10);
        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](count);

        uint256 total;
        for (uint256 i = 0; i < count; i++) {
            // Keep amounts nonzero and bounded so the running total can't overflow.
            uint256 amount = bound(rawAmounts[i], 1, 1e30);
            splits[i] = ITokenSplitter.Split({recipient: address(uint160(i + 1)), amount: amount});
            total += amount;
        }

        MockERC20 token = _deployAndApprove(total);
        splitter.initializeDistribution(address(token), total, abi.encode(splits), bytes32(0));

        for (uint256 i = 0; i < count; i++) {
            assertEq(token.balanceOf(splits[i].recipient), splits[i].amount);
        }
        assertEq(token.balanceOf(address(splitter)), 0);
    }
}
