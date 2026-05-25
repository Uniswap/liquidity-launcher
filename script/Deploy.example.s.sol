// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, stdJson} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Distribution} from "src/types/Distribution.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";
import {ILBPInitializer} from "src/interfaces/ILBPInitializer.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";

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

        // Existing-token flow: the broadcaster must have already approved Permit2 and set a Permit2 allowance for
        // the launcher. Do not pre-fund the launcher. Pull and distribute in the same multicall so the tokens never
        // rest in permissionless shared custody between transactions.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ILiquidityLauncher.depositToken, (token, uint160(totalSupply)));
        calls[1] = abi.encodeCall(ILiquidityLauncher.distributeToken, (token, distribution, salt));

        bytes[] memory results = IMulticall(liquidityLauncher).multicall(calls);
        IDistributionContract distributionContract = abi.decode(results[1], (IDistributionContract));

        // Sanity check: verify the deployed initializer references the correct token
        vm.assertEq(ILBPInitializer(address(distributionContract)).token(), token, "Token mismatch");
        console2.log("Distribution contract (CCA) deployed at:", address(distributionContract));

        vm.stopBroadcast();
    }
}
