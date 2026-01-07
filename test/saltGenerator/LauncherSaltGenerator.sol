pragma solidity ^0.8.0;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/// @notice SaltGenerator
/// Create uniswapv4 hook addresses via the token launcher strategy programatically
///
/// Example usage:
/// bytes32 salt = SaltGenerator.init()
///                        .withMask(SOME_MASK)
///                        .withMsgSender(the sender of the tx)
///                        .withStrategyAddress(the strategy being used - e.g. deployed lbpBasic)
///                        .withTokenLauncher(the address of the token launcher)
///                        .generate();
///
/// Under the hood it calls a program which will mine an address for you
/// Warning: before usage ensure that the binary has been built
contract SaltGenerator {
    address $msgSender;
    address $strategyFactoryAddress;
    address $tokenLauncher;
    address $mask;
    bytes32 $initCodeHash;

    Vm public constant vm = Vm(address(bytes20(uint160(uint256(keccak256("hevm cheat code"))))));

    constructor() {}

    function withMask(address _mask) public returns (SaltGenerator) {
        $mask = _mask;
        return this;
    }

    function withMsgSender(address _msgSender) public returns (SaltGenerator) {
        $msgSender = _msgSender;
        return this;
    }

    function withStrategyFactoryAddress(address _strategyFactoryAddress) public returns (SaltGenerator) {
        $strategyFactoryAddress = _strategyFactoryAddress;
        return this;
    }

    function withTokenLauncher(address _tokenLauncher) public returns (SaltGenerator) {
        $tokenLauncher = _tokenLauncher;
        return this;
    }

    function withInitCodeHash(bytes32 _initCodeHash) public returns (SaltGenerator) {
        $initCodeHash = _initCodeHash;
        return this;
    }

    function generate() public returns (bytes32) {
        string[] memory ffi_cmds = new string[](10);
        ffi_cmds[0] = "./shell-scripts/run-address-miner.sh";
        ffi_cmds[1] = vm.toString($initCodeHash);
        ffi_cmds[2] = vm.toString($mask);
        ffi_cmds[3] = "-m";
        ffi_cmds[4] = vm.toString($msgSender);
        ffi_cmds[5] = "-s";
        ffi_cmds[6] = vm.toString($strategyFactoryAddress);
        ffi_cmds[7] = "-l";
        ffi_cmds[8] = vm.toString($tokenLauncher);
        ffi_cmds[9] = "-q"; // quiet mode to not pollute stdout

        return abi.decode(vm.ffi(ffi_cmds), (bytes32));
    }
}
