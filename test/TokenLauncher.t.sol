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

contract TokenLauncherTest is Test, DeployPermit2 {
    TokenLauncher public tokenLauncher;
    IAllowanceTransfer permit2;
    UERC20Factory public uerc20Factory;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        tokenLauncher = new TokenLauncher(permit2);
        uerc20Factory = new UERC20Factory();
    }

    function _mockToken(address recipient, uint256 initialSupply, string memory name, string memory symbol)
        internal
        returns (address tokenAddress)
    {
        // Create the mock token
        MockERC20 token = new MockERC20(name, symbol, initialSupply, recipient);
        tokenAddress = address(token);

        // Set up tokenLauncher approval only when test contract is the creator
        if (recipient == address(this)) {
            // Set up permit2 approval
            token.approve(address(permit2), type(uint256).max);
            permit2.approve(tokenAddress, address(tokenLauncher), type(uint160).max, 0);
        }
    }

    function test_createToken_succeeds() public {
        // Create metadata for the UERC20 token
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher",
            website: "https://test.com",
            image: "https://test.com/image.png"
        });

        bytes memory tokenData = abi.encode(metadata);
        uint256 initialSupply = 1e18; // 1 token with 18 decimals

        address tokenAddress = tokenLauncher.createToken(
            address(uerc20Factory), "Test Token", "TEST", 18, initialSupply, address(tokenLauncher), tokenData
        );

        // Verify the token was created
        assertNotEq(tokenAddress, address(0));

        // Cast to UERC20 and verify properties
        UERC20 token = UERC20(tokenAddress);
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), initialSupply);

        // Verify the TokenLauncher received the initial supply
        assertEq(token.balanceOf(address(tokenLauncher)), initialSupply);

        // Verify the creator is set correctly (should be the TokenLauncher since it calls the factory)
        assertEq(token.creator(), address(tokenLauncher));

        // Verify the graffiti is set correctly
        assertEq(token.graffiti(), keccak256(abi.encode(address(this))));

        // Verify metadata
        (string memory description, string memory website, string memory image) = token.metadata();
        assertEq(description, "Test token for launcher");
        assertEq(website, "https://test.com");
        assertEq(image, "https://test.com/image.png");
    }

    function test_distributeToken_strategy_succeeds() public {
        uint256 initialSupply = 1e18;
        address tokenAddress = _mockToken(address(tokenLauncher), initialSupply, "Test Token", "TEST");

        // Create a distribution strategy
        MockDistributionStrategy distributionStrategy = new MockDistributionStrategy();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategy), amount: initialSupply, configData: ""});

        // Distribute the token
        // payer is the token launcher
        IDistributionContract distributionContract = tokenLauncher.distributeToken(tokenAddress, distribution, false);

        // Verify the distribution was successful
        assertEq(IERC20(tokenAddress).balanceOf(address(distributionContract)), initialSupply);

        // verify the token launcher has no balance of the token
        assertEq(IERC20(tokenAddress).balanceOf(address(tokenLauncher)), 0);
    }

    function test_distributeToken_strategyAndContract_succeeds() public {
        uint256 initialSupply = 1e18;
        address tokenAddress = _mockToken(address(tokenLauncher), initialSupply, "Test Token", "TEST");

        // Create a distribution strategy and contract
        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: initialSupply, configData: ""});

        // Distribute the token
        IDistributionContract distributionContract = tokenLauncher.distributeToken(tokenAddress, distribution, false);

        // verify the distribution contract is the same as the strategy
        assertEq(address(distributionContract), address(distributionStrategyAndContract));

        // Verify the distribution was successful
        assertEq(IERC20(tokenAddress).balanceOf(address(distributionContract)), initialSupply);

        // verify the token launcher has no balance of the token
        assertEq(IERC20(tokenAddress).balanceOf(address(tokenLauncher)), 0);
    }

    function test_payerIsUser_succeeds() public {
        uint256 initialSupply = 1e18;
        address tokenAddress = _mockToken(address(this), initialSupply, "Test Token", "TEST");

        // Create a distribution strategy and contract
        MockDistributionStrategyAndContract distributionStrategyAndContract = new MockDistributionStrategyAndContract();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategyAndContract), amount: initialSupply, configData: ""});

        // approve the token launcher to spend the token
        IERC20(tokenAddress).approve(address(tokenLauncher), initialSupply);

        // Distribute the token
        IDistributionContract distributionContract = tokenLauncher.distributeToken(tokenAddress, distribution, true);

        // verify the distribution contract is the same as the strategy
        assertEq(address(distributionContract), address(distributionStrategyAndContract));

        // Verify the distribution was successful
        assertEq(IERC20(tokenAddress).balanceOf(address(distributionContract)), initialSupply);

        // verify the token launcher has no balance of the token
        assertEq(IERC20(tokenAddress).balanceOf(address(tokenLauncher)), 0);

        // verify the user does not have any balance of the token
        assertEq(IERC20(tokenAddress).balanceOf(address(this)), 0);
    }

    function test_getGraffiti_succeeds() public view {
        bytes32 graffiti = tokenLauncher.getGraffiti(address(this));
        assertEq(graffiti, keccak256(abi.encode(address(this))));
    }

    // forge-config: default.isolate = true
    // forge-config: ci.isolate = true
    function test_createToken_gas() public {
        // Create metadata for the UERC20 token
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher",
            website: "https://test.com",
            image: "https://test.com/image.png"
        });

        bytes memory tokenData = abi.encode(metadata);
        uint256 initialSupply = 1e18; // 1 token with 18 decimals

        tokenLauncher.createToken(
            address(uerc20Factory), "Test Token", "TEST", 18, initialSupply, address(tokenLauncher), tokenData
        );
        vm.snapshotGasLastCall("createToken");
    }

    // forge-config: default.isolate = true
    // forge-config: ci.isolate = true
    function test_distributeToken_gas() public {
        uint256 initialSupply = 1e18;
        address tokenAddress = _mockToken(address(tokenLauncher), initialSupply, "Test Token", "TEST");

        // Create a distribution strategy
        MockDistributionStrategy distributionStrategy = new MockDistributionStrategy();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(distributionStrategy), amount: initialSupply, configData: ""});

        // Distribute the token
        tokenLauncher.distributeToken(tokenAddress, distribution, false);
        vm.snapshotGasLastCall("distributeToken");
    }
}
