// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {UERC20} from "@uniswap/uerc20-factory/src/tokens/UERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Distribution} from "src/types/Distribution.sol";
import {TokenSplitter} from "src/strategies/TokenSplitter.sol";
import {ITokenSplitter} from "src/interfaces/ITokenSplitter.sol";

/// @notice End-to-end tests: create a token in the launcher and split it to EOAs/multisigs in one multicall.
contract TokenSplitterE2ETest is Test, DeployPermit2 {
    LiquidityLauncher public liquidityLauncher;
    IAllowanceTransfer permit2;
    UERC20Factory public uerc20Factory;
    TokenSplitter public splitter;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        liquidityLauncher = new LiquidityLauncher(permit2);
        uerc20Factory = new UERC20Factory();
        splitter = new TokenSplitter();
    }

    function test_multicall_create_and_split_token() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address multisig = makeAddr("multisig");

        uint128 initialSupply = 1_000_000e18;

        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](3);
        splits[0] = ITokenSplitter.Split({recipient: alice, amount: 500_000e18});
        splits[1] = ITokenSplitter.Split({recipient: bob, amount: 300_000e18});
        splits[2] = ITokenSplitter.Split({recipient: multisig, amount: 200_000e18});

        Distribution memory distribution =
            Distribution({strategy: address(splitter), amount: initialSupply, configData: abi.encode(splits)});

        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for splitter",
            website: "https://test.com",
            image: "https://test.com/image.png",
            xProofTweetId: 0
        });
        bytes memory tokenData = abi.encode(metadata);

        bytes32 graffiti = liquidityLauncher.getGraffiti(address(this));
        address precomputedAddress =
            uerc20Factory.getUERC20Address("Test Token", "TEST", 18, address(liquidityLauncher), graffiti);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            LiquidityLauncher.createToken.selector,
            address(uerc20Factory),
            "Test Token",
            "TEST",
            18,
            initialSupply,
            address(liquidityLauncher),
            tokenData
        );
        calls[1] = abi.encodeWithSelector(
            LiquidityLauncher.distributeToken.selector, precomputedAddress, distribution, bytes32(0)
        );

        liquidityLauncher.multicall(calls);

        UERC20 token = UERC20(precomputedAddress);
        assertEq(token.totalSupply(), initialSupply);
        assertEq(token.balanceOf(alice), 500_000e18);
        assertEq(token.balanceOf(bob), 300_000e18);
        assertEq(token.balanceOf(multisig), 200_000e18);
        // Nothing should be left in the launcher or the splitter.
        assertEq(token.balanceOf(address(liquidityLauncher)), 0);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function test_multicall_revertsWhenSplitsUnderAllocateLauncherAllowance() public {
        address alice = makeAddr("alice");

        uint128 initialSupply = 1_000_000e18;

        // Only allocate part of the supply: the splitter reverts with InvalidSplit before the launcher's
        // AllowanceNotFullyConsumed check is reached.
        ITokenSplitter.Split[] memory splits = new ITokenSplitter.Split[](1);
        splits[0] = ITokenSplitter.Split({recipient: alice, amount: 400_000e18});

        Distribution memory distribution =
            Distribution({strategy: address(splitter), amount: initialSupply, configData: abi.encode(splits)});

        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for splitter",
            website: "https://test.com",
            image: "https://test.com/image.png",
            xProofTweetId: 0
        });
        bytes memory tokenData = abi.encode(metadata);

        bytes32 graffiti = liquidityLauncher.getGraffiti(address(this));
        address precomputedAddress =
            uerc20Factory.getUERC20Address("Test Token", "TEST", 18, address(liquidityLauncher), graffiti);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            LiquidityLauncher.createToken.selector,
            address(uerc20Factory),
            "Test Token",
            "TEST",
            18,
            initialSupply,
            address(liquidityLauncher),
            tokenData
        );
        calls[1] = abi.encodeWithSelector(
            LiquidityLauncher.distributeToken.selector, precomputedAddress, distribution, bytes32(0)
        );

        vm.expectRevert(abi.encodeWithSelector(ITokenSplitter.InvalidSplit.selector, 400_000e18, initialSupply));
        liquidityLauncher.multicall(calls);
    }
}
