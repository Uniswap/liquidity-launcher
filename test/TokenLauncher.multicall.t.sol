// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TokenLauncher} from "../src/TokenLauncher.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "../src/token-factories/uerc20-factory/factories/UERC20Factory.sol";
import {UERC20Metadata} from "../src/token-factories/uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {UERC20} from "../src/token-factories/uerc20-factory/tokens/UERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockDistributionStrategy} from "./mocks/MockDistributionStrategy.sol";
import {Distribution} from "../src/types/Distribution.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IDistributionContract} from "../src/interfaces/IDistributionContract.sol";
import {MockDistributionStrategyAndContract} from "./mocks/MockDistributionStrategyAndContract.sol";
import {Permit2Forwarder} from "../src/Permit2Forwarder.sol";
import {Permit2SignatureHelpers} from "./shared/Permit2SignatureHelpers.sol";

contract TokenLauncherTest is Test, DeployPermit2, Permit2SignatureHelpers {
    TokenLauncher public tokenLauncher;
    IAllowanceTransfer permit2;
    UERC20Factory public uerc20Factory;
    bytes32 PERMIT2_DOMAIN_SEPARATOR;
    address bob;
    uint256 bobPK;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        tokenLauncher = new TokenLauncher(permit2);
        uerc20Factory = new UERC20Factory();

        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();

        (bob, bobPK) = makeAddrAndKey("BOB");
    }

    function test_multicall_create_and_distribute_token() public {
        // Create a token
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher",
            website: "https://test.com",
            image: "https://test.com/image.png"
        });

        uint256 initialSupply = 1e18;

        // Create a distribution strategy and contract
        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: initialSupply, configData: ""});

        bytes32 graffiti = tokenLauncher.getGraffiti(address(this));

        address precomputedAddress =
            uerc20Factory.getUERC20Address("Test Token", "TEST", 18, address(tokenLauncher), graffiti);

        bytes memory tokenData = abi.encode(metadata);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            TokenLauncher.createToken.selector,
            address(uerc20Factory),
            "Test Token",
            "TEST",
            18,
            initialSupply,
            address(tokenLauncher),
            tokenData
        );
        calls[1] =
            abi.encodeWithSelector(TokenLauncher.distributeToken.selector, precomputedAddress, distribution, false);

        tokenLauncher.multicall(calls);

        // Verify the token was created
        assertNotEq(precomputedAddress, address(0));

        // Cast to UERC20 and verify properties
        UERC20 token = UERC20(precomputedAddress);
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), initialSupply);

        // Verify the creator is set correctly (should be the TokenLauncher since it calls the factory)
        assertEq(token.creator(), address(tokenLauncher));

        // Verify metadata
        (string memory description, string memory website, string memory image) = token.metadata();
        assertEq(description, "Test token for launcher");
        assertEq(website, "https://test.com");
        assertEq(image, "https://test.com/image.png");

        // Verify the distribution was successful
        assertEq(IERC20(precomputedAddress).balanceOf(address(distributionStrategyAndContract)), initialSupply);

        // verify the token launcher has no balance of the token
        assertEq(token.balanceOf(address(tokenLauncher)), 0);
    }

    function test_multicall_permit_and_distribute_token() public {
        uint256 initialSupply = 1e18;
        MockERC20 token = new MockERC20("Test Token", "TEST", initialSupply, bob);
        // Set up permit2 approval
        vm.prank(bob);
        token.approve(address(permit2), type(uint256).max);

        // Create a distribution strategy and contract
        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: initialSupply, configData: ""});

        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(token), type(uint160).max, uint48(block.timestamp + 10e18), 0);
        permit.spender = address(tokenLauncher);
        bytes memory sig = getPermitSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(TokenLauncher.distributeToken.selector, address(token), distribution, true);

        vm.prank(bob);
        tokenLauncher.multicall(calls);

        // Verify the distribution was successful
        assertEq(IERC20(address(token)).balanceOf(address(distributionStrategyAndContract)), initialSupply);

        // verify the token launcher has no balance of the token
        assertEq(token.balanceOf(address(tokenLauncher)), 0);
    }

    // forge-config: default.isolate = true
    // forge-config: ci.isolate = true
    function test_multicall_create_and_distribute_token_gas() public {
        // Create a token
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher",
            website: "https://test.com",
            image: "https://test.com/image.png"
        });

        uint256 initialSupply = 1e18;

        // Create a distribution strategy and contract
        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: initialSupply, configData: ""});

        bytes32 graffiti = tokenLauncher.getGraffiti(address(this));

        address precomputedAddress =
            uerc20Factory.getUERC20Address("Test Token", "TEST", 18, address(tokenLauncher), graffiti);

        bytes memory tokenData = abi.encode(metadata);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            TokenLauncher.createToken.selector,
            address(uerc20Factory),
            "Test Token",
            "TEST",
            18,
            initialSupply,
            address(tokenLauncher),
            tokenData
        );
        calls[1] =
            abi.encodeWithSelector(TokenLauncher.distributeToken.selector, precomputedAddress, distribution, false);

        tokenLauncher.multicall(calls);
        vm.snapshotGasLastCall("multicall create and distribute token");
    }

    // forge-config: default.isolate = true
    // forge-config: ci.isolate = true
    function test_multicall_permit_and_distribute_token_gas() public {
        uint256 initialSupply = 1e18;
        MockERC20 token = new MockERC20("Test Token", "TEST", initialSupply, bob);
        // Set up permit2 approval
        vm.prank(bob);
        token.approve(address(permit2), type(uint256).max);

        // Create a distribution strategy and contract
        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: initialSupply, configData: ""});

        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(token), type(uint160).max, uint48(block.timestamp + 10e18), 0);
        permit.spender = address(tokenLauncher);
        bytes memory sig = getPermitSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(TokenLauncher.distributeToken.selector, address(token), distribution, true);

        vm.prank(bob);
        tokenLauncher.multicall(calls);
        vm.snapshotGasLastCall("multicall permit and distribute token");
    }
}
