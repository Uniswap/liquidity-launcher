// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LBPStrategyBasic} from "../../src/distributionContracts/LBPStrategyBasic.sol";
import {MigratorParameters} from "../../src/distributionContracts/LBPStrategyBasic.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {MockDistributionStrategy} from "../mocks/MockDistributionStrategy.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LBPStrategyBasicNoValidation} from "../mocks/LBPStrategyBasicNoValidation.sol";
import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";
import {TokenLauncher} from "../../src/TokenLauncher.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract LBPStrategyBasicTest is Test, DeployPermit2 {
    LBPStrategyBasicNoValidation lbp;
    IAllowanceTransfer permit2 = IAllowanceTransfer(deployPermit2());
    TokenLauncher tokenLauncher = new TokenLauncher(permit2);
    MockERC20 token = new MockERC20("Test Token", "TEST", 1000e18, address(tokenLauncher));
    PoolManager poolManager = new PoolManager(address(this));
    MockDistributionStrategy mock = new MockDistributionStrategy();
    uint256 totalSupply = 1000e18;

    // Create a mock position manager address
    address mockPositionManager = address(0x1234567890123456789012345678901234567890);

    function setUp() public {
        // Deploy the contract without validation - we'll test it at its deployed address
        lbp = new LBPStrategyBasicNoValidation(
            address(token),
            totalSupply,
            abi.encode(
                MigratorParameters({
                    currency: address(0),
                    fee: 500,
                    positionManager: mockPositionManager,
                    tickSpacing: 100,
                    poolManager: address(poolManager),
                    tokenSplit: 5000,
                    auctionFactory: address(mock),
                    positionRecipient: address(this),
                    migrationBlock: uint64(block.number + 1000)
                }),
                bytes("")
            )
        );
    }

    function test_setUpProperly() public view {
        assertEq(lbp.tokenAddress(), address(token));
        assertEq(lbp.currency(), address(0));
        assertEq(lbp.totalSupply(), 1000e18);
        assertEq(address(lbp.positionManager()), address(0x1234567890123456789012345678901234567890));
        assertEq(lbp.positionRecipient(), address(this));
        assertEq(lbp.migrationBlock(), uint64(block.number + 1000));
        assertEq(lbp.auctionFactory(), address(mock));
        assertEq(lbp.tokenSplit(), 5000);
        assertEq(lbp.auction(), address(0));

        // Get the pool key components from the contract
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) = lbp.key();

        // Test pool key properties
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token));
        assertEq(fee, 500);
        assertEq(tickSpacing, 100);
        assertEq(address(hooks), address(lbp));
    }

    function test_onTokenReceived_revertsWithInvalidToken() public {
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.InvalidToken.selector));
        lbp.onTokensReceived(address(0), 1000e18);
    }

    function test_onTokenReceived_revertsWithIncorrectTokenSupply() public {
        vm.prank(address(tokenLauncher));
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.IncorrectTokenSupply.selector));
        lbp.onTokensReceived(address(token), totalSupply - 1);
    }

    function test_onTokenReceived_revertsWithInvalidAmountReceived() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply - 1);
        vm.expectRevert(abi.encodeWithSelector(IDistributionContract.InvalidAmountReceived.selector));
        lbp.onTokensReceived(address(token), totalSupply);
    }

    function test_onTokenReceived_createsAuction() public {
        vm.prank(address(tokenLauncher));
        token.transfer(address(lbp), totalSupply);
        lbp.onTokensReceived(address(token), totalSupply);
        assertEq(lbp.auction(), address(0));
    }
}
