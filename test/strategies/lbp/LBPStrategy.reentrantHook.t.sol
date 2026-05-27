// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPStrategyTestBase} from "./base/LBPStrategyTestBase.sol";
import {ILBPInitializer, LBPInitializationParams} from "src/interfaces/ILBPInitializer.sol";
import {IStrategy} from "src/interfaces/IStrategy.sol";
import {MigratorParameters, LiquidityAllocationBracket, MigratorParams} from "src/libraries/MigratorParams.sol";
import {PositionDefinition} from "src/types/PositionPlannerTypes.sol";
import {InitializerHook} from "src/periphery/hooks/InitializerHook.sol";
import {MockLBPInitializer} from "test/mocks/MockLBPInitializer.sol";
import {MockERC20} from "test/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {PoolParameters} from "src/libraries/MigratorParams.sol";

contract ReentrantInitializeHookNoValidation is InitializerHook {
    address public attackToken;
    uint256 public attackTotalSupply;
    bytes public attackConfigData;
    bytes32 public attackSalt;
    bool public armedReentry;
    bool public armedDonation;
    bool public executed;

    constructor(IPoolManager _poolManager, address _strategy) InitializerHook(_poolManager, _strategy) {}

    function validateHookAddress(BaseHook) internal pure override {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions = super.getHookPermissions();
        permissions.afterInitialize = true;
    }

    function armReentry(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt) external {
        attackToken = token;
        attackTotalSupply = totalSupply;
        attackConfigData = configData;
        attackSalt = salt;
        armedReentry = true;
        IERC20(token).approve(authorized, totalSupply);
    }

    function armDonation(address token, uint256 amount) external {
        attackToken = token;
        attackTotalSupply = amount;
        armedDonation = true;
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal override returns (bytes4) {
        if (!executed && armedReentry) {
            executed = true;
            IStrategy(authorized).initializeDistribution(attackToken, attackTotalSupply, attackConfigData, attackSalt);
        } else if (!executed && armedDonation) {
            executed = true;
            IERC20(attackToken).transfer(authorized, attackTotalSupply);
        }
        return IHooks.afterInitialize.selector;
    }
}

contract LBPStrategyReentrantHookTest is LBPStrategyTestBase {
    address internal attacker = makeAddr("attacker");
    address internal victimLauncher = makeAddr("victimLauncher");
    address internal victimLeftoverRecipient = makeAddr("victimLeftoverRecipient");

    uint128 internal constant VICTIM_RESERVE = 100e18;
    uint128 internal constant ATTACKER_PHANTOM_RESERVE = 100e18;
    uint128 internal constant VICTIM_AUCTION_SUPPLY = 1e18;
    uint128 internal constant ATTACKER_B_AUCTION_SUPPLY = 1e18;
    uint128 internal constant ATTACKER_B_SUPPLY_FOR_LP = 1e18;
    uint128 internal constant ATTACKER_C_AUCTION_SUPPLY = 1e18;

    function test_reentrantHookCannotRegisterPhantomReserveDuringMigrate() public {
        uint64 migrationBlock = uint64(block.number + 5);
        uint64 endBlock = migrationBlock - 1;
        uint160 initialPriceX96 = uint160((uint256(1) << 192) / type(uint160).max + 1);
        LiquidityAllocationBracket[] memory fullAllocation = _fullAllocation();

        MockERC20 xToken = new MockERC20(
            "Shared Token",
            "X",
            uint256(VICTIM_RESERVE + VICTIM_AUCTION_SUPPLY + ATTACKER_PHANTOM_RESERVE + ATTACKER_C_AUCTION_SUPPLY),
            address(this)
        );
        MockERC20 yToken = new MockERC20(
            "Attack Launch Token", "Y", ATTACKER_B_SUPPLY_FOR_LP + ATTACKER_B_AUCTION_SUPPLY, address(this)
        );

        xToken.transfer(victimLauncher, VICTIM_RESERVE + VICTIM_AUCTION_SUPPLY);
        xToken.transfer(attacker, ATTACKER_PHANTOM_RESERVE + ATTACKER_C_AUCTION_SUPPLY);
        yToken.transfer(attacker, ATTACKER_B_SUPPLY_FOR_LP + ATTACKER_B_AUCTION_SUPPLY);

        ReentrantInitializeHookNoValidation hook = _deployMaliciousHook();

        _registerVictimLaunch(xToken, migrationBlock, endBlock, fullAllocation);
        assertEq(xToken.balanceOf(address(strategy)), VICTIM_RESERVE);

        bytes memory attackerCConfig = _zeroAuctionConfig(
            address(xToken),
            address(0),
            attacker,
            address(0),
            migrationBlock,
            ATTACKER_PHANTOM_RESERVE,
            endBlock,
            fullAllocation
        );

        MockLBPInitializer attackerBInitializer =
            _registerAttackerBLaunch(yToken, xToken, hook, migrationBlock, endBlock, fullAllocation, initialPriceX96);

        vm.startPrank(attacker);
        xToken.transfer(address(hook), ATTACKER_PHANTOM_RESERVE + ATTACKER_C_AUCTION_SUPPLY);
        hook.armReentry(
            address(xToken),
            ATTACKER_PHANTOM_RESERVE + ATTACKER_C_AUCTION_SUPPLY,
            attackerCConfig,
            bytes32("attacker-c")
        );
        vm.stopPrank();

        vm.roll(migrationBlock);
        vm.expectRevert();
        vm.prank(attacker);
        strategy.migrate(ILBPInitializer(address(attackerBInitializer)));
    }

    function test_afterInitializeTokenInflationIsNotSweptAsMigrateLeftoverCurrency() public {
        uint64 migrationBlock = uint64(block.number + 5);
        uint64 endBlock = migrationBlock - 1;
        uint160 initialPriceX96 = uint160((uint256(1) << 192) / type(uint160).max + 1);
        LiquidityAllocationBracket[] memory fullAllocation = _fullAllocation();

        MockERC20 xToken = new MockERC20(
            "Shared Token", "X", VICTIM_RESERVE + VICTIM_AUCTION_SUPPLY + ATTACKER_PHANTOM_RESERVE, address(this)
        );
        MockERC20 yToken = new MockERC20(
            "Attack Launch Token", "Y", ATTACKER_B_SUPPLY_FOR_LP + ATTACKER_B_AUCTION_SUPPLY, address(this)
        );

        xToken.transfer(victimLauncher, VICTIM_RESERVE + VICTIM_AUCTION_SUPPLY);
        xToken.transfer(attacker, ATTACKER_PHANTOM_RESERVE);
        yToken.transfer(attacker, ATTACKER_B_SUPPLY_FOR_LP + ATTACKER_B_AUCTION_SUPPLY);

        ReentrantInitializeHookNoValidation hook = _deployMaliciousHook();

        _registerVictimLaunch(xToken, migrationBlock, endBlock, fullAllocation);
        MockLBPInitializer attackerBInitializer =
            _registerAttackerBLaunch(yToken, xToken, hook, migrationBlock, endBlock, fullAllocation, initialPriceX96);

        vm.startPrank(attacker);
        xToken.transfer(address(hook), ATTACKER_PHANTOM_RESERVE);
        hook.armDonation(address(xToken), ATTACKER_PHANTOM_RESERVE);
        vm.stopPrank();

        uint256 attackerBalanceBefore = xToken.balanceOf(attacker);

        vm.roll(migrationBlock);
        vm.prank(attacker);
        strategy.migrate(ILBPInitializer(address(attackerBInitializer)));

        assertTrue(hook.executed(), "hook donation did not execute");
        assertEq(xToken.balanceOf(attacker), attackerBalanceBefore, "hook-seeded token was swept to attacker");
        assertEq(
            xToken.balanceOf(address(strategy)),
            VICTIM_RESERVE + ATTACKER_PHANTOM_RESERVE,
            "hook-seeded token should remain unattributed"
        );
    }

    function _registerVictimLaunch(
        MockERC20 xToken,
        uint64 migrationBlock,
        uint64 endBlock,
        LiquidityAllocationBracket[] memory fullAllocation
    ) internal returns (MockLBPInitializer victimInitializer) {
        bytes memory victimConfig = _zeroAuctionConfig(
            address(xToken),
            address(0),
            victimLeftoverRecipient,
            address(0),
            migrationBlock,
            VICTIM_RESERVE,
            endBlock,
            fullAllocation
        );

        vm.startPrank(victimLauncher);
        xToken.approve(address(strategy), VICTIM_RESERVE + VICTIM_AUCTION_SUPPLY);
        strategy.initializeDistribution(
            address(xToken), VICTIM_RESERVE + VICTIM_AUCTION_SUPPLY, victimConfig, bytes32("victim")
        );
        vm.stopPrank();

        victimInitializer = factory.deployedInitializer();
    }

    function _registerAttackerBLaunch(
        MockERC20 yToken,
        MockERC20 xToken,
        ReentrantInitializeHookNoValidation hook,
        uint64 migrationBlock,
        uint64 endBlock,
        LiquidityAllocationBracket[] memory fullAllocation,
        uint160 initialPriceX96
    ) internal returns (MockLBPInitializer attackerBInitializer) {
        bytes memory attackerBConfig = _attackerBConfig(
            address(yToken), address(xToken), address(hook), migrationBlock, endBlock, fullAllocation, initialPriceX96
        );

        vm.startPrank(attacker);
        yToken.approve(address(strategy), ATTACKER_B_SUPPLY_FOR_LP + ATTACKER_B_AUCTION_SUPPLY);
        strategy.initializeDistribution(
            address(yToken),
            ATTACKER_B_SUPPLY_FOR_LP + ATTACKER_B_AUCTION_SUPPLY,
            attackerBConfig,
            bytes32("attacker-b")
        );
        vm.stopPrank();

        attackerBInitializer = factory.deployedInitializer();
    }

    function _deployMaliciousHook() internal returns (ReentrantInitializeHookNoValidation hook) {
        address hookAddr = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG));
        ReentrantInitializeHookNoValidation impl =
            new ReentrantInitializeHookNoValidation(IPoolManager(address(POOL_MANAGER)), address(strategy));
        vm.etch(hookAddr, address(impl).code);
        hook = ReentrantInitializeHookNoValidation(hookAddr);
    }

    function _migratorParams(
        address token,
        address currency,
        address recipient,
        address hook,
        uint64 migrationBlock,
        uint128 reservedTokenAmountForLP
    ) internal view returns (MigratorParameters memory mp) {
        mp = MigratorParameters({
            token: token,
            currency: currency,
            migrationBlock: migrationBlock,
            reservedTokenAmountForLP: reservedTokenAmountForLP,
            recipient: recipient,
            poolParameters: PoolParameters({fee: 0, tickSpacing: 1, hook: hook}),
            positionDefinitions: _fullRangePositionDefinitions(),
            lpAllocationSchedule: new bytes(0)
        });
    }

    function _fullRangePositionDefinitions() internal view returns (bytes memory) {
        PositionDefinition[] memory defs = new PositionDefinition[](1);
        defs[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK, offsetUpper: TickMath.MAX_TICK, weight: 1e7, recipient: positionRecipient
        });
        return abi.encode(defs);
    }

    function _fullAllocation() internal pure returns (LiquidityAllocationBracket[] memory fullAllocation) {
        fullAllocation = new LiquidityAllocationBracket[](1);
        fullAllocation[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: MigratorParams.MAX_BRACKET_RATE});
    }

    function _zeroAuctionConfig(
        address token,
        address currency,
        address leftover,
        address hook,
        uint64 migrationBlock,
        uint128 supplyForLP,
        uint64 endBlock,
        LiquidityAllocationBracket[] memory fullAllocation
    ) internal view returns (bytes memory) {
        return _encodeConfigData(
            _migratorParams(token, currency, leftover, hook, migrationBlock, supplyForLP),
            fullAllocation,
            _encodeMockInitializerParams(
                endBlock, address(0), LBPInitializationParams({initialPriceX96: 0, tokensSold: 0, currencyRaised: 0})
            )
        );
    }

    function _attackerBConfig(
        address token,
        address currency,
        address hook,
        uint64 migrationBlock,
        uint64 endBlock,
        LiquidityAllocationBracket[] memory fullAllocation,
        uint160 initialPriceX96
    ) internal view returns (bytes memory) {
        return _encodeConfigData(
            _migratorParams(token, currency, attacker, hook, migrationBlock, ATTACKER_B_SUPPLY_FOR_LP),
            fullAllocation,
            _encodeMockInitializerParams(
                endBlock,
                currency,
                LBPInitializationParams({
                    initialPriceX96: initialPriceX96, tokensSold: ATTACKER_B_AUCTION_SUPPLY, currencyRaised: 0
                })
            )
        );
    }
}
