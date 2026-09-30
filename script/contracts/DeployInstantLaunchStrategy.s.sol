// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {InstantLaunchStrategy, LaunchPoolConfig} from "../../src/strategies/InstantLaunchStrategy.sol";
import {console} from "forge-std/console.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {DeployParameters, Parameters} from "./Parameters.sol";
import {IFeeSplitter} from "../../src/interfaces/IFeeSplitter.sol";
import {IBeneficiaryVault} from "../../src/interfaces/IBeneficiaryVault.sol";

contract DeployInstantLaunchStrategyScript is Script, Parameters {
    // Defaults match the reviewed mainnet native-ETH launch configuration. Override with
    // QUOTE_CURRENCY / MIN_LAUNCH_TICK / MAX_INITIAL_TICK / INITIAL_TICK for other chains
    // (for example ARC USDC at 0x3600…0000).
    address internal constant DEFAULT_QUOTE_CURRENCY = address(0);
    int256 internal constant DEFAULT_MIN_LAUNCH_TICK = -160_100;
    int256 internal constant DEFAULT_MAX_INITIAL_TICK = 251_325;
    int256 internal constant DEFAULT_INITIAL_TICK = 198_050;

    function run(address feeSplitter, address beneficiaryVault) public returns (address instantLaunchStrategy) {
        DeployParameters memory params = getParameters(block.chainid);
        address liquidityLauncher = vm.envAddress("LIQUIDITY_LAUNCHER");
        if (liquidityLauncher == address(0)) revert("env: LIQUIDITY_LAUNCHER not set");

        Currency quoteCurrency = Currency.wrap(vm.envOr("QUOTE_CURRENCY", DEFAULT_QUOTE_CURRENCY));
        int24 minLaunchTick = int24(vm.envOr("MIN_LAUNCH_TICK", DEFAULT_MIN_LAUNCH_TICK));
        int24 maxInitialTick = int24(vm.envOr("MAX_INITIAL_TICK", DEFAULT_MAX_INITIAL_TICK));
        int24 initialTick = int24(vm.envOr("INITIAL_TICK", DEFAULT_INITIAL_TICK));
        // For native (ETH) quote the default 20_000_000 ether is safe.
        // For ERC20 quotes, minQuoteBlockerCost is interpreted in quote-token base units
        // (e.g. 6-dec USDC: set MIN_QUOTE_BLOCKER_COST=20000000000000 for 20_000_000e6).
        // ERC20 deploys MUST set MIN_QUOTE_BLOCKER_COST explicitly; there is no safe default.
        uint256 minQuoteBlockerCost;
        if (Currency.unwrap(quoteCurrency) == address(0)) {
            minQuoteBlockerCost = vm.envOr("MIN_QUOTE_BLOCKER_COST", uint256(20_000_000 ether));
        } else {
            minQuoteBlockerCost = vm.envUint("MIN_QUOTE_BLOCKER_COST");
            if (minQuoteBlockerCost == 0) {
                revert("env: MIN_QUOTE_BLOCKER_COST must be set (non-zero) for ERC20 quote deployments");
            }
        }
        console.log("Quote currency:", Currency.unwrap(quoteCurrency));
        console.log("Initial tick:");
        console.logInt(int256(initialTick));
        console.log("Min launch tick:");
        console.logInt(int256(minLaunchTick));
        console.log("Max initial tick:");
        console.logInt(int256(maxInitialTick));
        console.log("Min quote blocker cost:", minQuoteBlockerCost);

        bytes memory bytecode = abi.encodePacked(
            type(InstantLaunchStrategy).creationCode,
            abi.encode(
                liquidityLauncher,
                params.positionManager,
                params.poolManager,
                IFeeSplitter(feeSplitter),
                IBeneficiaryVault(beneficiaryVault),
                LaunchPoolConfig({
                    quoteCurrency: quoteCurrency,
                    initialTick: initialTick,
                    minLaunchTick: minLaunchTick,
                    maxInitialTick: maxInitialTick,
                    minQuoteBlockerCost: minQuoteBlockerCost
                })
            )
        );
        bytes32 initCodeHash = keccak256(bytecode);

        bytes32 salt = vm.envOr("GLOBAL_SALT", bytes32(0));

        address expectedAddress = Create2.computeAddress(salt, initCodeHash, DEFAULT_CREATE2_DEPLOYER);
        if (expectedAddress.code.length > 0) {
            console.log("Skipping deployment of InstantLaunchStrategy as it already exists at", expectedAddress);
            return expectedAddress;
        }

        vm.broadcast();
        instantLaunchStrategy = Create2.deploy(0, salt, bytecode);
        console.log("InstantLaunchStrategy deployed to:", instantLaunchStrategy);
        return instantLaunchStrategy;
    }
}
