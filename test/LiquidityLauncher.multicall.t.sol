// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {UERC20} from "@uniswap/uerc20-factory/src/tokens/UERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Distribution} from "src/types/Distribution.sol";
import {MockDistributionStrategyAndContract} from "./mocks/MockDistributionStrategyAndContract.sol";

contract LiquidityLauncherTest is Test {
    LiquidityLauncher public liquidityLauncher;
    UERC20Factory public uerc20Factory;

    function setUp() public {
        liquidityLauncher = new LiquidityLauncher();
        uerc20Factory = new UERC20Factory();
    }

    function test_multicall_create_and_distribute_token() public {
        // Create a token
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher", website: "https://test.com", image: "https://test.com/image.png"
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

        // Verify the token was created
        assertNotEq(precomputedAddress, address(0));

        // Cast to UERC20 and verify properties
        UERC20 token = UERC20(precomputedAddress);
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), initialSupply);

        // Verify the creator is set correctly (should be the LiquidityLauncher since it calls the factory)
        assertEq(token.creator(), address(liquidityLauncher));

        // Verify metadata
        (string memory description, string memory website, string memory image) = token.metadata();
        assertEq(description, "Test token for launcher");
        assertEq(website, "https://test.com");
        assertEq(image, "https://test.com/image.png");

        // Verify the distribution was successful
        assertEq(IERC20(precomputedAddress).balanceOf(address(distributionStrategyAndContract)), initialSupply);

        // verify the liquidity launcher has no balance of the token
        assertEq(token.balanceOf(address(liquidityLauncher)), 0);
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_multicall_create_and_distribute_token_gas() public {
        // Create a token
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher", website: "https://test.com", image: "https://test.com/image.png"
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
}
