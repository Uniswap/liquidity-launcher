// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {UERC20} from "@uniswap/uerc20-factory/src/tokens/UERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {MockUnderClaimingStrategy} from "./mocks/MockUnderClaimingStrategy.sol";
import {Distribution} from "src/types/Distribution.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockStrategyAndDistributor} from "./mocks/MockStrategyAndDistributor.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";

contract LiquidityLauncherTest is Test, DeployPermit2 {
    LiquidityLauncher public liquidityLauncher;
    IAllowanceTransfer permit2;
    UERC20Factory public uerc20Factory;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        liquidityLauncher = new LiquidityLauncher(permit2);
        uerc20Factory = new UERC20Factory();
    }

    function _mockToken(address recipient, uint256 initialSupply, string memory name, string memory symbol)
        internal
        returns (address tokenAddress)
    {
        MockERC20 token = new MockERC20(name, symbol, initialSupply, recipient);
        tokenAddress = address(token);
    }

    function test_fuzz_createToken_succeeds(uint128 initialSupply) public {
        // UERC20Factory rejects totalSupply == 0.
        initialSupply = uint128(bound(initialSupply, 1, type(uint128).max));

        // Create metadata for the UERC20 token
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher",
            website: "https://test.com",
            image: "https://test.com/image.png",
            xProofTweetId: 0
        });

        bytes memory tokenData = abi.encode(metadata);

        address tokenAddress = liquidityLauncher.createToken(
            address(uerc20Factory), "Test Token", "TEST", 18, initialSupply, address(liquidityLauncher), tokenData
        );

        // Verify the token was created
        assertNotEq(tokenAddress, address(0));

        // Cast to UERC20 and verify properties
        UERC20 token = UERC20(tokenAddress);
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), initialSupply);

        // Verify the LiquidityLauncher received the initial supply
        assertEq(token.balanceOf(address(liquidityLauncher)), initialSupply);

        // Verify the creator is set correctly (should be the LiquidityLauncher since it calls the factory)
        assertEq(token.creator(), address(liquidityLauncher));

        // Verify the graffiti is set correctly
        assertEq(token.graffiti(), keccak256(abi.encode(address(this))));

        // Verify metadata
        (string memory description, string memory website, string memory image, uint256 xProofTweetId) =
            token.metadata();
        assertEq(description, "Test token for launcher");
        assertEq(website, "https://test.com");
        assertEq(image, "https://test.com/image.png");
        assertEq(xProofTweetId, 0);
    }

    function test_createToken_revertsWithRecipientCannotBeZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ILiquidityLauncher.RecipientCannotBeZeroAddress.selector));
        liquidityLauncher.createToken(
            address(uerc20Factory),
            "Test Token",
            "TEST",
            18,
            1e18,
            address(0),
            abi.encode(
                UERC20Metadata({
                    description: "Test token for launcher",
                    website: "https://test.com",
                    image: "https://test.com/image.png",
                    xProofTweetId: 0
                })
            )
        );
    }

    function test_fuzz_distributeToken_strategy_succeeds(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));
        address tokenAddress = _mockToken(address(liquidityLauncher), amount, "Test Token", "TEST");

        // Create a strategy
        MockStrategy strategy = new MockStrategy();

        // Create a distribution
        Distribution memory distribution = Distribution({strategy: address(strategy), amount: amount, configData: ""});

        // Distribute the token
        vm.expectEmit(true, true, false, true);
        emit ILiquidityLauncher.TokenDistributed(tokenAddress, address(strategy), amount);
        liquidityLauncher.distributeToken(tokenAddress, distribution, bytes32(0));

        // Verify the distribution was successful
        assertEq(IERC20(tokenAddress).balanceOf(address(strategy.distributor())), amount);

        // verify the liquidity launcher has no balance of the token
        assertEq(IERC20(tokenAddress).balanceOf(address(liquidityLauncher)), 0);
    }

    function test_fuzz_distributeToken_strategyAndDistributor_succeeds(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));
        address tokenAddress = _mockToken(address(liquidityLauncher), amount, "Test Token", "TEST");

        // Create a strategy that is also a distributor
        MockStrategyAndDistributor strategyAndDistributor = new MockStrategyAndDistributor();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(strategyAndDistributor), amount: amount, configData: ""});

        // Distribute the token
        liquidityLauncher.distributeToken(tokenAddress, distribution, bytes32(0));

        // Verify the distribution was successful
        assertEq(IERC20(tokenAddress).balanceOf(address(strategyAndDistributor)), amount);

        // verify the liquidity launcher has no balance of the token
        assertEq(IERC20(tokenAddress).balanceOf(address(liquidityLauncher)), 0);
    }

    function test_fuzz_distributeToken_revertsWhenLauncherHasInsufficientBalance(uint128 amount) public {
        // No tokens are minted into the launcher — calling distributeToken makes the strategy try
        // to pull from a zero balance, which reverts in safeTransferFrom.
        amount = uint128(bound(amount, 1, type(uint128).max));
        address tokenAddress = _mockToken(address(this), amount, "Test Token", "TEST");
        assertEq(IERC20(tokenAddress).balanceOf(address(liquidityLauncher)), 0);

        MockStrategy strategy = new MockStrategy();
        Distribution memory distribution = Distribution({strategy: address(strategy), amount: amount, configData: ""});

        vm.expectRevert();
        liquidityLauncher.distributeToken(tokenAddress, distribution, bytes32(0));
    }

    /// @notice distributeToken must revert if the strategy pulls less than the full pre-approved amount.
    function test_fuzz_distributeToken_revertsWhenStrategyDoesNotExhaustAllowance(uint128 amount, uint256 shortfall)
        public
    {
        amount = uint128(bound(amount, 2, type(uint128).max));
        shortfall = bound(shortfall, 1, amount);

        address tokenAddress = _mockToken(address(liquidityLauncher), amount, "Test Token", "TEST");
        MockUnderClaimingStrategy underClaimer = new MockUnderClaimingStrategy(shortfall);

        Distribution memory distribution =
            Distribution({strategy: address(underClaimer), amount: amount, configData: ""});

        vm.expectRevert(abi.encodeWithSelector(ILiquidityLauncher.AllowanceNotFullyConsumed.selector));
        liquidityLauncher.distributeToken(tokenAddress, distribution, bytes32(0));
    }

    /// @notice distributeToken must revert if the launcher holds more than the distribution consumes,
    /// leaving a residual balance that any caller could later route to an arbitrary strategy.
    function test_fuzz_distributeToken_revertsWhenResidualBalanceRemains(uint128 total, uint128 distributionAmount)
        public
    {
        total = uint128(bound(total, 2, type(uint128).max));
        distributionAmount = uint128(bound(distributionAmount, 1, total - 1));

        address tokenAddress = _mockToken(address(liquidityLauncher), total, "Test Token", "TEST");
        MockStrategy strategy = new MockStrategy();

        // The strategy pulls (and fully consumes the allowance for) only `distributionAmount`,
        // leaving `total - distributionAmount` stranded in the launcher.
        Distribution memory distribution =
            Distribution({strategy: address(strategy), amount: distributionAmount, configData: ""});

        vm.expectRevert(abi.encodeWithSelector(ILiquidityLauncher.NonZeroResidualBalance.selector));
        liquidityLauncher.distributeToken(tokenAddress, distribution, bytes32(0));
    }

    function test_fuzz_depositToken_revertsWithoutPermit2Allowance(uint128 amount) public {
        // The caller approves Permit2 on the token but never grants the launcher a Permit2 allowance,
        // so the launcher's permit2.transferFrom inside depositToken reverts (no allowance).
        amount = uint128(bound(amount, 1, type(uint128).max));
        MockERC20 token = new MockERC20("Test Token", "TEST", amount, address(this));
        token.approve(address(permit2), type(uint256).max);

        vm.expectRevert();
        liquidityLauncher.depositToken(address(token), uint160(amount));
    }

    /// @notice Documents the held-tokens footgun: tokens minted into the launcher (or deposited via
    /// `depositToken`) without being followed by `distributeToken` in the same multicall can be picked
    /// up by ANY caller, who can route them to an arbitrary strategy. This is the reason the launcher's
    /// docs and natspec require batching token acquisition and distribution inside one multicall.
    function test_fuzz_heldTokens_canBeDistributedByAnyone(uint128 amount) public {
        amount = uint128(bound(amount, 1, type(uint128).max));
        address alice = makeAddr("alice");
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher",
            website: "https://test.com",
            image: "https://test.com/image.png",
            xProofTweetId: 0
        });

        vm.prank(alice);
        address tokenAddress = liquidityLauncher.createToken(
            address(uerc20Factory), "Test Token", "TEST", 18, amount, address(liquidityLauncher), abi.encode(metadata)
        );
        assertEq(IERC20(tokenAddress).balanceOf(address(liquidityLauncher)), amount);

        // Bob — a completely unrelated caller — picks up Alice's held tokens by calling distributeToken
        // with his own strategy. There is no on-chain authorization tying the tokens to Alice.
        address bob = makeAddr("bob");
        MockStrategyAndDistributor bobsStrategy = new MockStrategyAndDistributor();
        Distribution memory distribution =
            Distribution({strategy: address(bobsStrategy), amount: amount, configData: ""});

        vm.prank(bob);
        liquidityLauncher.distributeToken(tokenAddress, distribution, bytes32(0));

        assertEq(IERC20(tokenAddress).balanceOf(address(bobsStrategy)), amount);
        assertEq(IERC20(tokenAddress).balanceOf(address(liquidityLauncher)), 0);
    }

    function test_fuzz_depositToken_pullsFromCaller(uint128 amount, uint48 deadlineOffset) public {
        amount = uint128(bound(amount, 1, type(uint128).max));
        deadlineOffset = uint48(bound(deadlineOffset, 1, type(uint48).max - block.timestamp));
        uint48 deadline = uint48(block.timestamp) + deadlineOffset;

        MockERC20 token = new MockERC20("Test Token", "TEST", amount, address(this));
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(liquidityLauncher), uint160(amount), deadline);

        liquidityLauncher.depositToken(address(token), uint160(amount));

        assertEq(IERC20(address(token)).balanceOf(address(liquidityLauncher)), amount);
        assertEq(IERC20(address(token)).balanceOf(address(this)), 0);
    }

    function test_getGraffiti_succeeds() public view {
        bytes32 graffiti = liquidityLauncher.getGraffiti(address(this));
        assertEq(graffiti, keccak256(abi.encode(address(this))));
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_createToken_gas() public {
        // Create metadata for the UERC20 token
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test token for launcher",
            website: "https://test.com",
            image: "https://test.com/image.png",
            xProofTweetId: 0
        });

        bytes memory tokenData = abi.encode(metadata);
        uint128 initialSupply = 1e18; // 1 token with 18 decimals

        liquidityLauncher.createToken(
            address(uerc20Factory), "Test Token", "TEST", 18, initialSupply, address(liquidityLauncher), tokenData
        );
        vm.snapshotGasLastCall("createToken");
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_distributeToken_gas() public {
        uint128 initialSupply = 1e18;
        address tokenAddress = _mockToken(address(liquidityLauncher), initialSupply, "Test Token", "TEST");

        // Create a strategy
        MockStrategy strategy = new MockStrategy();

        // Create a distribution
        Distribution memory distribution =
            Distribution({strategy: address(strategy), amount: initialSupply, configData: ""});

        // Distribute the token
        liquidityLauncher.distributeToken(tokenAddress, distribution, bytes32(0));
        vm.snapshotGasLastCall("distributeToken");
    }
}
