// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullRangeLBPStrategy} from "src/strategies/lbp/FullRangeLBPStrategy.sol";
import {Script, stdJson} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Distribution} from "src/types/Distribution.sol";
import {IStrategyFactory} from "src/interfaces/IStrategyFactory.sol";
import {ILiquidityLauncher} from "src/interfaces/ILiquidityLauncher.sol";
import {ILBPStrategyBase} from "src/interfaces/ILBPStrategyBase.sol";
import {MigratorParameters} from "src/types/MigratorParameters.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {Parameters} from "./contracts/Parameters.sol";
import {SaltGenerator} from "test/saltGenerator/LauncherSaltGenerator.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice Example script for a token distribution. By defualt supports only the FullRangeLBPStrategy.
/// @dev You should fork this and fill in the values in `example.json`
contract DeployExample is Script, Parameters {
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
        address strategyFactory = input.readAddress(string.concat(chainIdSlug, ".strategyFactory"));

        // create the distribution instruction
        Distribution memory distribution =
            Distribution({strategy: strategyFactory, amount: totalSupply, configData: configData});

        // Approve permit2 for the total supply amount
        ERC20(token).approve(PERMIT2, totalSupply);
        SafeTransferLib.permit2Approve(token, address(liquidityLauncher), uint160(totalSupply), type(uint48).max);
        bool payerIsUser = true;

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(FullRangeLBPStrategy).creationCode,
                abi.encode(
                    token,
                    uint128(totalSupply),
                    migratorParameters,
                    initializerParameters,
                    getParameters(block.chainid).positionManager,
                    getParameters(block.chainid).poolManager
                )
            )
        );
        address poolMask = address(BEFORE_INITIALIZE_FLAG_MASK);

        vm.stopBroadcast();

        // Don't broadcast the following since it will actually deploy a SaltGenerator
        bytes32 topLevelSalt = new SaltGenerator().withInitCodeHash(initCodeHash).withMask(poolMask)
            .withMsgSender(msg.sender).withTokenLauncher(liquidityLauncher).withStrategyFactoryAddress(strategyFactory)
            .generate();

        vm.startBroadcast();

        // Begin the distribution
        IDistributionContract strategy =
            ILiquidityLauncher(liquidityLauncher).distributeToken(token, distribution, payerIsUser, topLevelSalt);

        vm.assertGt(address(strategy).code.length, 0, "Strategy contract not deployed");
        console2.log("Strategy contract deployed at:", address(strategy));
        // sanity check
        vm.assertEq(ILBPStrategyBase(address(strategy)).token(), token, "Token mismatch");

        vm.stopBroadcast();
    }
}
