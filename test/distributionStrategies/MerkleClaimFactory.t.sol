// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {MerkleClaimFactory} from "../../src/factories/periphery/MerkleClaimFactory.sol";
import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";

interface IMerkleClaim {
    function token() external view returns (address);
    function merkleRoot() external view returns (bytes32);
    function owner() external view returns (address);
    function endTime() external view returns (uint256);
}

contract MerkleClaimFactoryTest is Test {
    uint128 constant TOTAL_SUPPLY = 1000e18;

    MerkleClaimFactory public factory;
    address token;
    address owner;

    bytes32 merkleRoot;
    uint256 endTime;
    bytes configData;

    function setUp() public {
        factory = new MerkleClaimFactory();
        token = makeAddr("token");

        // Setup merkle claim parameters
        merkleRoot = keccak256("test merkle root");
        owner = makeAddr("owner");
        endTime = block.timestamp + 1 days;
        configData = abi.encode(merkleRoot, owner, endTime);
    }

    function test_initializeDistribution_succeeds() public {
        bytes32 salt = 0x7fa9385be102ac3eac297483dd6233d62b3e1496c857faf801c8174cae36c06f;

        IMerkleClaim merkleClaim =
            IMerkleClaim(address(factory.initializeDistribution(token, TOTAL_SUPPLY, configData, salt)));

        assertEq(merkleClaim.token(), token);
        assertEq(merkleClaim.merkleRoot(), merkleRoot);
        assertEq(merkleClaim.owner(), owner);
        assertEq(merkleClaim.endTime(), endTime);
    }

    function test_getAddress_succeeds() public {
        bytes32 salt = 0x7fa9385be102ac3eac297483dd6233d62b3e1496c857faf801c8174cae36c06f;

        // Get the predicted address
        address predictedAddress = factory.getAddress(token, TOTAL_SUPPLY, configData, salt, address(this));

        // Deploy the actual contract
        IDistributionContract deployedContract = factory.initializeDistribution(token, TOTAL_SUPPLY, configData, salt);

        // Verify the addresses match
        assertEq(address(deployedContract), predictedAddress);
    }
}
