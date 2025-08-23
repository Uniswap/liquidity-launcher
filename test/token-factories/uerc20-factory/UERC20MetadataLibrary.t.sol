// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {
    UERC20MetadataLibrary,
    UERC20Metadata
} from "../../../src/token-factories/uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract UERC20MetadataLibraryTest is Test {
    using UERC20MetadataLibrary for UERC20Metadata;

    function testToJSON_ValidMetadata() public pure {
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "Test Token",
            website: "https://example.com",
            image: "https://example.com/image.png"
        });

        string memory result = metadata.toJSON();

        // Expected JSON with all fields
        string memory expectedJson =
            '{"description":"Test Token", "website":"https://example.com", "image":"https://example.com/image.png"}';
        string memory expectedBase64 = Base64.encode(bytes(expectedJson));
        string memory expected = string(abi.encodePacked("data:application/json;base64,", expectedBase64));

        assertEq(result, expected);
    }

    function testToJSON_EmptyMetadata() public pure {
        UERC20Metadata memory metadata = UERC20Metadata({description: "", website: "", image: ""});

        string memory result = metadata.toJSON();

        // Expected JSON for empty metadata
        string memory expectedJson = "{}";
        string memory expectedBase64 = Base64.encode(bytes(expectedJson));
        string memory expected = string(abi.encodePacked("data:application/json;base64,", expectedBase64));

        assertEq(result, expected);
    }

    function testToJSON_PartialMetadata() public pure {
        UERC20Metadata memory metadata = UERC20Metadata({description: "Test Token", website: "", image: ""});

        string memory result = metadata.toJSON();

        // Expected JSON with only creator and description fields
        string memory expectedJson = '{"description":"Test Token"}';
        string memory expectedBase64 = Base64.encode(bytes(expectedJson));
        string memory expected = string(abi.encodePacked("data:application/json;base64,", expectedBase64));

        assertEq(result, expected);
    }
}
