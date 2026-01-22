// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullRangeLBPStrategy} from "src/strategies/lbp/FullRangeLBPStrategy.sol";
import {Script, stdJson} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Distribution} from "src/types/Distribution.sol";
import {IStrategyFactory} from "src/interfaces/IStrategyFactory.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";

/// @notice Example script for a token distribution
/// @dev You should fork this and fill in the values in `example.json`
contract DeployExample is Script {
    using stdJson for string;

    function run() external {
        vm.startBroadcast();

        string memory input = vm.readFile("script/example.json");

        string memory chainIdSlug = string(abi.encodePacked('["', vm.toString(block.chainid), '"]'));
        address token = input.readAddress(string.concat(chainIdSlug, ".token"));
        uint128 totalSupply = uint128(input.readUint(string.concat(chainIdSlug, ".totalSupply")));
        bytes memory configData = input.readBytes(string.concat(chainIdSlug, ".configData"));
        bytes32 salt = input.readBytes32(string.concat(chainIdSlug, ".salt"));
        address liquidityLauncher = input.readAddress(string.concat(chainIdSlug, ".liquidityLauncher"));
        address strategyFactory = input.readAddress(string.concat(chainIdSlug, ".strategyFactory"));

        // Salts end up being nested with the msg.sender of each call
        // The first salt calculated by liquidity launcher uses the originator of the call
        bytes32 liquidityLauncherSalt = keccak256(abi.encode(msg.sender, salt));
        bytes32 strategySalt = keccak256(abi.encode(liquidityLauncher, liquidityLauncherSalt));

        // Get the predicted address of the strategy contract
        address strategy = IStrategyFactory(strategyFactory)
            .getAddress(token, totalSupply, configData, strategySalt, liquidityLauncher);

        // create the distribution instruction
        Distribution memory distribution =
            Distribution({strategy: strategyFactory, amount: totalSupply, configData: configData});

        // Requires the caller of the script to have approved the liquidity launcher
        bool payerIsUser = true;

        // Begin the distribution
        ILiquidityLauncher(liquidityLauncher).distributeToken(token, distribution, payerIsUser, salt);

        vm.assertGt(strategy.code.length, 0, "Strategy contract not deployed");
        console2.log("Strategy contract deployed at:", address(strategy));
        // sanity check
        vm.assertEq(ILBPStrategyBase(strategy).token(), token, "Token mismatch");

        vm.stopBroadcast();
    }
}
