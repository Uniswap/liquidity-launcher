// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, stdJson} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Distribution} from "src/types/Distribution.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";

/// @notice Example script for distributing a token via LBPStrategy
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
        address lbpStrategy = input.readAddress(string.concat(chainIdSlug, ".lbpStrategy"));

        Distribution memory distribution =
            Distribution({strategy: lbpStrategy, amount: totalSupply, configData: configData});

        // The launcher must already hold `totalSupply` of `token` before this call.
        // Begin the distribution. The configured strategy pulls tokens from the launcher.
        ILiquidityLauncher(liquidityLauncher).distributeToken(token, distribution, salt);
        console2.log("Distribution strategy initialized:", lbpStrategy);

        vm.stopBroadcast();
    }
}
