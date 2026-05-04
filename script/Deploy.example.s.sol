// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, stdJson} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Distribution} from "src/types/Distribution.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";

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

        // Requires the caller of the script to have approved the liquidity launcher
        bool payerIsUser = true;

        // Begin the distribution — LBPStrategy deploys a CCA initializer and returns its address
        IDistributionContract distributionContract =
            ILiquidityLauncher(liquidityLauncher).distributeToken(token, distribution, payerIsUser, salt);

        // Sanity check: verify the deployed initializer references the correct token
        vm.assertEq(ILBPInitializer(address(distributionContract)).token(), token, "Token mismatch");
        console2.log("Distribution contract (CCA) deployed at:", address(distributionContract));

        vm.stopBroadcast();
    }
}
