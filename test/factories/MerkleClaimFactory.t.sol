// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MerkleClaimFactory} from "src/factories/periphery/MerkleClaimFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IMerkleClaim {
    function token() external view returns (address);
    function merkleRoot() external view returns (bytes32);
    function owner() external view returns (address);
    function endTime() external view returns (uint256);
}

contract MerkleClaimFactoryTest is Test {
    uint128 constant TOTAL_SUPPLY = 1000e18;

    MerkleClaimFactory public factory;
    MockERC20 token;
    address owner;

    bytes32 merkleRoot;
    uint256 endTime;
    bytes configData;

    function setUp() public {
        factory = new MerkleClaimFactory();
        token = new MockERC20("Test Token", "TT", TOTAL_SUPPLY, address(this));

        // Setup merkle claim parameters
        merkleRoot = keccak256("test merkle root");
        owner = makeAddr("owner");
        endTime = block.timestamp + 1 days;
        configData = abi.encode(merkleRoot, owner, endTime);
    }

    function test_initializeDistribution_succeeds() public {
        bytes32 salt = 0x7fa9385be102ac3eac297483dd6233d62b3e1496c857faf801c8174cae36c06f;

        token.approve(address(factory), TOTAL_SUPPLY);

        vm.recordLogs();
        factory.initializeDistribution(address(token), TOTAL_SUPPLY, configData, salt);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 initializedTopic = keccak256("DistributionInitialized(address,address,uint256)");
        address merkleClaimAddress;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].topics[0] == initializedTopic) {
                merkleClaimAddress = address(uint160(uint256(entries[i].topics[1])));
                break;
            }
        }
        assertNotEq(merkleClaimAddress, address(0));
        IMerkleClaim merkleClaim = IMerkleClaim(merkleClaimAddress);

        assertEq(merkleClaim.token(), address(token));
        assertEq(merkleClaim.merkleRoot(), merkleRoot);
        assertEq(merkleClaim.owner(), owner);
        assertEq(merkleClaim.endTime(), endTime);
        assertEq(IERC20(address(token)).balanceOf(address(merkleClaim)), TOTAL_SUPPLY);
    }
}
