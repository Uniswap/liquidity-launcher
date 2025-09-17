// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

import "forge-std/Test.sol";
import {MerkleClaimFactory} from "../../src/distributionStrategies/MerkleClaimFactory.sol";
import {MerkleClaim} from "../../src/distributionContracts/MerkleClaim.sol";
import {IDistributionContract} from "../../src/interfaces/IDistributionContract.sol";

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

        MerkleClaim merkleClaim =
            MerkleClaim(address(factory.initializeDistribution(token, TOTAL_SUPPLY, configData, salt)));

        assertEq(merkleClaim.token(), token);
        assertEq(merkleClaim.merkleRoot(), merkleRoot);
        assertEq(merkleClaim.owner(), owner);
        assertEq(merkleClaim.endTime(), endTime);
    }

    function test_getMerkleClaimAddress_succeeds() public {
        bytes32 salt = 0x7fa9385be102ac3eac297483dd6233d62b3e1496c857faf801c8174cae36c06f;

        // Get the predicted address
        address predictedAddress = factory.getMerkleClaimAddress(token, configData, salt, address(this));

        // Deploy the actual contract
        IDistributionContract deployedContract = factory.initializeDistribution(token, TOTAL_SUPPLY, configData, salt);

        // Verify the addresses match
        assertEq(address(deployedContract), predictedAddress);
    }
}
