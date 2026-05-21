// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {UERC20} from "@uniswap/uerc20-factory/src/tokens/UERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Distribution} from "src/types/Distribution.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDistributionStrategyAndContract} from "./mocks/MockDistributionStrategyAndContract.sol";
import {Permit2Forwarder} from "src/Permit2Forwarder.sol";
import {Permit2SignatureHelpers} from "./shared/Permit2SignatureHelpers.sol";

contract LiquidityLauncherTest is Test, DeployPermit2, Permit2SignatureHelpers {
    LiquidityLauncher public liquidityLauncher;
    IAllowanceTransfer permit2;
    UERC20Factory public uerc20Factory;
    bytes32 PERMIT2_DOMAIN_SEPARATOR;
    address bob;
    uint256 bobPK;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        liquidityLauncher = new LiquidityLauncher(permit2);
        uerc20Factory = new UERC20Factory();

        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        (bob, bobPK) = makeAddrAndKey("BOB");
    }

    function test_fuzz_multicall_create_and_distribute_token(uint128 initialSupply) public {
        // createToken takes a uint128 initialSupply; bound away from 0 so the distribution has something to do.
        initialSupply = uint128(bound(initialSupply, 1, type(uint128).max));

        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher",
            website: "https://test.com",
            image: "https://test.com/image.png",
            xProofTweetId: 0
        });

        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: initialSupply, configData: ""});

        bytes32 graffiti = liquidityLauncher.getGraffiti(address(this));
        address precomputedAddress =
            uerc20Factory.getUERC20Address("Test Token", "TEST", 18, address(liquidityLauncher), graffiti);

        bytes memory tokenData = abi.encode(metadata);

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
        assertEq(token.creator(), address(liquidityLauncher));

        // Verify metadata
        (string memory description, string memory website, string memory image, uint256 xProofTweetId) =
            token.metadata();
        assertEq(description, "Test token for launcher");
        assertEq(website, "https://test.com");
        assertEq(image, "https://test.com/image.png");
        assertEq(xProofTweetId, 0);

        // Verify the distribution was successful
        // The full balance ended up in the distribution contract; nothing held in the launcher.
        assertEq(IERC20(precomputedAddress).balanceOf(address(distributionStrategyAndContract)), initialSupply);
        assertEq(token.balanceOf(address(liquidityLauncher)), 0);
    }

    function test_fuzz_multicall_permit_deposit_and_distribute_token(uint128 amount, uint48 deadlineOffset) public {
        // Distribution.amount is uint128; bound away from 0 so the deposit moves something.
        amount = uint128(bound(amount, 1, type(uint128).max));
        // Deadline must be strictly in the future at sign + use time.
        deadlineOffset = uint48(bound(deadlineOffset, 1, type(uint48).max - block.timestamp));
        uint48 deadline = uint48(block.timestamp) + deadlineOffset;

        MockERC20 token = new MockERC20("Test Token", "TEST", amount, bob);
        vm.prank(bob);
        token.approve(address(permit2), type(uint256).max);

        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: amount, configData: ""});

        // Sign a permit2 allowance for the launcher to pull from bob.
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(token), uint160(amount), deadline, 0);
        permit.spender = address(liquidityLauncher);
        bytes memory sig = getPermitSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        // Atomic three-step: register permit2 allowance, pull bob's tokens into the launcher, then distribute.
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(LiquidityLauncher.depositToken.selector, address(token), uint160(amount));
        calls[2] = abi.encodeWithSelector(
            LiquidityLauncher.distributeToken.selector, address(token), distribution, bytes32(0)
        );

        vm.prank(bob);
        liquidityLauncher.multicall(calls);

        assertEq(IERC20(address(token)).balanceOf(address(distributionStrategyAndContract)), amount);
        assertEq(token.balanceOf(address(liquidityLauncher)), 0);
        assertEq(token.balanceOf(bob), 0);
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_multicall_create_and_distribute_token_gas() public {
        // Create a token
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher",
            website: "https://test.com",
            image: "https://test.com/image.png",
            xProofTweetId: 0
        });

        uint128 initialSupply = 1e18;

        // Create a distribution strategy and contract
        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: initialSupply, configData: ""});

        bytes32 graffiti = liquidityLauncher.getGraffiti(address(this));

        address precomputedAddress =
            uerc20Factory.getUERC20Address("Test Token", "TEST", 18, address(liquidityLauncher), graffiti);

        bytes memory tokenData = abi.encode(metadata);

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
        vm.snapshotGasLastCall("multicall create and distribute token");
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_multicall_permit_deposit_and_distribute_token_gas() public {
        uint128 amount = 1e18;
        uint48 deadline = uint48(block.timestamp + 1 days);

        MockERC20 token = new MockERC20("Test Token", "TEST", amount, bob);
        vm.prank(bob);
        token.approve(address(permit2), type(uint256).max);

        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: amount, configData: ""});

        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(token), uint160(amount), deadline, 0);
        permit.spender = address(liquidityLauncher);
        bytes memory sig = getPermitSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(LiquidityLauncher.depositToken.selector, address(token), uint160(amount));
        calls[2] = abi.encodeWithSelector(
            LiquidityLauncher.distributeToken.selector, address(token), distribution, bytes32(0)
        );

        vm.prank(bob);
        liquidityLauncher.multicall(calls);
        vm.snapshotGasLastCall("multicall permit deposit and distribute token");
    }
}
