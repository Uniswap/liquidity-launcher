// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, stdJson} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Distribution} from "src/types/Distribution.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";

/// @notice Example script for distributing a token via LBPStrategy
contract DeployExample is Script {
    using stdJson for string;
    using SafeCastLib for *;

    uint160 constant BEFORE_INITIALIZE_FLAG_MASK = 1 << 13;

    function run() external {
        vm.startBroadcast();

        string memory input = vm.readFile("script/example.json");

        string memory chainIdSlug = string(abi.encodePacked('["', vm.toString(block.chainid), '"]'));
        address token = input.readAddress(string.concat(chainIdSlug, ".token"));
        uint128 totalSupply = uint128(input.readUint(string.concat(chainIdSlug, ".totalSupply")));

        MigratorParameters memory migratorParameters = MigratorParameters({
            migrationBlock: input.readUint(string.concat(chainIdSlug, ".migratorParameters.migrationBlock")).toUint64(),
            currency: input.readAddress(string.concat(chainIdSlug, ".migratorParameters.currency")),
            poolLPFee: input.readUint(string.concat(chainIdSlug, ".migratorParameters.poolLPFee")).toUint24(),
            poolTickSpacing: input.readInt(string.concat(chainIdSlug, ".migratorParameters.poolTickSpacing")).toInt24(),
            tokenSplit: input.readUint(string.concat(chainIdSlug, ".migratorParameters.tokenSplit")).toUint24(),
            initializerFactory: input.readAddress(string.concat(chainIdSlug, ".migratorParameters.initializerFactory")),
            positionRecipient: input.readAddress(string.concat(chainIdSlug, ".migratorParameters.positionRecipient")),
            sweepBlock: input.readUint(string.concat(chainIdSlug, ".migratorParameters.sweepBlock")).toUint64(),
            operator: input.readAddress(string.concat(chainIdSlug, ".migratorParameters.operator")),
            maxCurrencyAmountForLP: input.readUint(
                    string.concat(chainIdSlug, ".migratorParameters.maxCurrencyAmountForLP")
                ).toUint128()
        });
        bytes memory initializerParameters = input.readBytes(string.concat(chainIdSlug, ".initializerParameters"));
        bytes memory configData = abi.encode(migratorParameters, initializerParameters);

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

        IMulticall(liquidityLauncher).multicall(calls);
        console2.log("Strategy initialized:", lbpStrategy);

        vm.stopBroadcast();
    }
}
