// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./strategies/lbp/base/LBPStrategyTestBase.sol";
import {Permit2SignatureHelpers} from "./shared/Permit2SignatureHelpers.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {Permit2Forwarder} from "src/Permit2Forwarder.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Distribution} from "src/types/Distribution.sol";
import {MigratorParameters, LiquidityAllocationBracket} from "src/libraries/MigratorParams.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice End-to-end integration test
contract LiquidityLauncherLBPIntegrationTest is LBPStrategyTestBase, DeployPermit2, Permit2SignatureHelpers {
    LiquidityLauncher launcher;
    IAllowanceTransfer permit2;
    UERC20Factory uerc20Factory;
    bytes32 PERMIT2_DOMAIN_SEPARATOR;
    address bob;
    uint256 bobPK;

    function setUp() public override {
        super.setUp();
        permit2 = IAllowanceTransfer(deployPermit2());
        launcher = new LiquidityLauncher(permit2);
        uerc20Factory = new UERC20Factory();
        PERMIT2_DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();
        (bob, bobPK) = makeAddrAndKey("BOB");
    }

    function test_fuzz_e2e_multicall_createTokenAndDistributeViaLBPStrategy(MigrationFuzzParams memory p) public {
        // Precompute the would-be token address so we can populate mp.token and build Distribution
        // before the multicall fires.
        address tokenAddress = uerc20Factory.getUERC20Address(
            "Test Token", "TEST", 18, address(launcher), launcher.getGraffiti(address(this))
        );

        (MigratorParameters memory mp, uint128 totalSupply, bytes memory configData) = _buildE2EConfig(p, tokenAddress);

        Distribution memory distribution =
            Distribution({strategy: address(strategy), amount: totalSupply, configData: configData});

        // Multicall the canonical fresh-mint flow: createToken into launcher → distributeToken via LBPStrategy.
        launcher.multicall(_buildCalls(tokenAddress, totalSupply, distribution));

        _assertE2EState(tokenAddress, mp.supplyForLP, totalSupply - mp.supplyForLP, mp.migrationBlock);
    }

    function test_fuzz_e2e_multicall_permitDepositAndDistributeViaLBPStrategy(
        MigrationFuzzParams memory p,
        uint48 deadlineOffset
    ) public {
        // Bound first so we know totalSupply (needed to mint bob's token before building configData).
        (uint128 totalSupply,) = _boundForE2E(p);
        MockERC20 token = new MockERC20("Test Token", "TEST", totalSupply, bob);
        vm.prank(bob);
        token.approve(address(permit2), type(uint256).max);

        (MigratorParameters memory mp,, bytes memory configData) = _buildE2EConfig(p, address(token));

        Distribution memory distribution =
            Distribution({strategy: address(strategy), amount: totalSupply, configData: configData});

        // Atomic three-step: register permit2 allowance, pull bob's tokens into the launcher, distribute.
        vm.prank(bob);
        launcher.multicall(
            _buildPermitDepositDistributeCalls(address(token), totalSupply, deadlineOffset, distribution)
        );

        _assertE2EState(address(token), mp.supplyForLP, totalSupply - mp.supplyForLP, mp.migrationBlock);
        // Bob is left with no tokens — the launcher pulled the full balance from him.
        assertEq(token.balanceOf(bob), 0);
    }

    /// @notice Lightweight bounding helper that returns just the supply numbers (no encoding).
    /// Useful when the caller needs to know totalSupply before the token address is known.
    function _boundForE2E(MigrationFuzzParams memory p)
        internal
        view
        returns (uint128 totalSupply, uint128 auctionSupply)
    {
        (, totalSupply,, auctionSupply) = _boundMigratorParams(p);
    }

    /// @notice Bounds the full MigrationFuzzParams and returns the strategy inputs needed to drive
    /// either e2e flow (fresh-mint or permit-deposit). The `tokenAddress` must equal the token that
    /// will actually be pulled by the launcher — it's baked into mp.token for the strategy's
    /// registration-time validation.
    function _buildE2EConfig(MigrationFuzzParams memory p, address tokenAddress)
        internal
        view
        returns (MigratorParameters memory mp, uint128 totalSupply, bytes memory configData)
    {
        LiquidityAllocationBracket[] memory bp = _boundBrackets(p.bpParams);
        uint64 endBlock;
        uint128 auctionSupply;
        (mp, totalSupply, endBlock, auctionSupply) = _boundMigratorParams(p);
        p.currencyRaised = _boundCurrencyRaised(p.currencyRaised, bp);
        p.initialPriceX96 = _boundInitialPriceX96(p.initialPriceX96);
        p.tokensSold = uint128(bound(p.tokensSold, 1, auctionSupply));

        mp.token = tokenAddress;
        mp.currency = address(0);
        configData = _encodeConfigData(
            mp,
            bp,
            _encodeMockInitializerParams(
                endBlock,
                address(0),
                LBPInitializationParams({
                    initialPriceX96: p.initialPriceX96, tokensSold: p.tokensSold, currencyRaised: p.currencyRaised
                })
            )
        );
    }

    function _buildPermitDepositDistributeCalls(
        address tokenAddress,
        uint128 totalSupply,
        uint48 deadlineOffset,
        Distribution memory distribution
    ) internal view returns (bytes[] memory calls) {
        // Permit2 deadline must be strictly in the future when the permit is consumed.
        uint48 deadline = uint48(block.timestamp) + uint48(bound(deadlineOffset, 1, type(uint48).max - block.timestamp));
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(tokenAddress, uint160(totalSupply), deadline, 0);
        permit.spender = address(launcher);
        bytes memory sig = getPermitSignature(permit, bobPK, PERMIT2_DOMAIN_SEPARATOR);

        calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(Permit2Forwarder.permit.selector, bob, permit, sig);
        calls[1] = abi.encodeWithSelector(LiquidityLauncher.depositToken.selector, tokenAddress, uint160(totalSupply));
        calls[2] =
            abi.encodeWithSelector(LiquidityLauncher.distributeToken.selector, tokenAddress, distribution, bytes32(0));
    }

    function _buildCalls(address tokenAddress, uint128 totalSupply, Distribution memory distribution)
        internal
        view
        returns (bytes[] memory calls)
    {
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "E2E test token",
            website: "https://test.com",
            image: "https://test.com/image.png",
            xProofTweetId: 0
        });

        calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            LiquidityLauncher.createToken.selector,
            address(uerc20Factory),
            "Test Token",
            "TEST",
            18,
            totalSupply,
            address(launcher),
            abi.encode(metadata)
        );
        calls[1] =
            abi.encodeWithSelector(LiquidityLauncher.distributeToken.selector, tokenAddress, distribution, bytes32(0));
    }

    function _assertE2EState(address tokenAddress, uint128 supplyForLP, uint128 auctionSupply, uint64 migrationBlock)
        internal
        view
    {
        MockLBPInitializer initializer = factory.deployedInitializer();

        // Launcher should have no balance — it handed everything off to the strategy.
        assertEq(IERC20(tokenAddress).balanceOf(address(launcher)), 0);
        // Strategy holds the LP portion; initializer holds the auction portion.
        assertEq(IERC20(tokenAddress).balanceOf(address(strategy)), supplyForLP);
        assertEq(IERC20(tokenAddress).balanceOf(address(initializer)), auctionSupply);
        // Reserves tracks the strategy's portion.
        assertEq(strategy.reserves(ILBPInitializer(address(initializer))), supplyForLP);

        // MigratorParameters were stored correctly on the strategy.
        MigratorParameters memory stored = strategy.initializers(ILBPInitializer(address(initializer)));
        assertEq(stored.migrationBlock, migrationBlock);
        assertEq(stored.supplyForLP, supplyForLP);
        assertEq(stored.leftoverRecipient, leftoverRecipient);
    }
}
