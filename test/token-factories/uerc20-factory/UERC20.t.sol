// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UERC20} from "../../../src/token-factories/uerc20-factory/tokens/UERC20.sol";
import {UERC20Factory} from "../../../src/token-factories/uerc20-factory/factories/UERC20Factory.sol";
import {UERC20Metadata} from "../../../src/token-factories/uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {Base64} from "./libraries/base64.sol";
import {Strings} from "@openzeppelin-latest/contracts/utils/Strings.sol";
import {IERC165} from "@optimism/interfaces/L2/IERC7802.sol";
import {IERC20} from "@openzeppelin-latest/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin-latest/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract UERC20Test is Test {
    using Base64 for string;
    using Strings for address;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 constant INITIAL_BALANCE = 5e18;
    uint256 constant TRANSFER_AMOUNT = 1e18;
    uint8 constant DECIMALS = 18;

    UERC20 token;
    UERC20Factory factory;
    UERC20Metadata tokenMetadata;

    address recipient = makeAddr("recipient");
    address bob = makeAddr("bob");

    struct JsonTokenAllFields {
        string description;
        string image;
        string website;
    }

    struct JsonTokenDescriptionWebsite {
        string description;
        string website;
    }

    struct JsonTokenDescriptionImage {
        string description;
        string image;
    }

    struct JsonTokenWebsiteImage {
        string image;
        string website;
    }

    struct JsonTokenDescription {
        string description;
    }

    struct JsonTokenWebsite {
        string website;
    }

    struct JsonTokenImage {
        string image;
    }

    function setUp() public {
        tokenMetadata = UERC20Metadata({
            description: "A test token",
            website: "https://example.com",
            image: "https://example.com/image.png"
        });
        factory = new UERC20Factory();
        token = UERC20(
            factory.createToken(
                "Test", "TEST", DECIMALS, INITIAL_BALANCE, recipient, abi.encode(tokenMetadata), bytes32("test")
            )
        );
    }

    function test_uerc20_data_succeeds() public view {
        assertEq(token.graffiti(), bytes32("test"));
        assertEq(token.creator(), address(this));
    }

    function test_uerc20_permit2CanTransferWithoutAllowance() public {
        vm.startPrank(PERMIT2);
        token.transferFrom(recipient, bob, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(recipient), INITIAL_BALANCE - TRANSFER_AMOUNT);
        vm.stopPrank();
    }

    function test_uerc20_nonPermit2CannotTransferWithoutAllowance() public {
        vm.startPrank(bob);
        vm.expectRevert();
        token.transferFrom(recipient, bob, TRANSFER_AMOUNT);
        vm.stopPrank();
    }

    function test_uerc20_nonPermit2CanTransferWithAllowance() public {
        vm.prank(recipient);
        token.approve(bob, TRANSFER_AMOUNT);

        vm.prank(bob);
        token.transferFrom(recipient, bob, TRANSFER_AMOUNT);

        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(recipient), INITIAL_BALANCE - TRANSFER_AMOUNT);
        assertEq(token.allowance(recipient, bob), 0);
    }

    function test_uerc20_permit2InfiniteAllowance() public view {
        assertEq(token.allowance(recipient, PERMIT2), type(uint256).max);
    }

    function test_uerc20_nameSymbolDecimalsTotalSupply() public view {
        assertEq(token.name(), "Test");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), DECIMALS);
        assertEq(token.totalSupply(), INITIAL_BALANCE);
    }

    function test_uerc20superchain_supportsInterface() public view {
        assertTrue(bytes4(0x01ffc9a7) == type(IERC165).interfaceId);
        assertTrue(token.supportsInterface(0x01ffc9a7)); // IERC165
        assertTrue(bytes4(0x36372b07) == type(IERC20).interfaceId);
        assertTrue(token.supportsInterface(0x36372b07)); // IERC20
        assertTrue(bytes4(0x9d8ff7da) == type(IERC20Permit).interfaceId);
        assertTrue(token.supportsInterface(0x9d8ff7da)); // IERC20Permit
    }

    function test_uerc20superchain_fuzz_supportsInterface(bytes4 interfaceId) public view {
        vm.assume(interfaceId != type(IERC165).interfaceId);
        vm.assume(interfaceId != type(IERC20).interfaceId);
        vm.assume(interfaceId != type(IERC20Permit).interfaceId);
        assertFalse(token.supportsInterface(interfaceId));
    }

    function test_uerc20_tokenURI_allFields() public view {
        bytes memory data = decode(token);
        JsonTokenAllFields memory jsonToken = abi.decode(data, (JsonTokenAllFields));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
        assertEq(jsonToken.website, "https://example.com");
        assertEq(jsonToken.image, "https://example.com/image.png");
    }

    function test_uerc20_tokenURI_maliciousInjectionDetected() public {
        tokenMetadata = UERC20Metadata({
            description: "A test token",
            website: "https://example.com",
            image: "Normal description\" , \"Website\": \"https://malicious.com"
        });
        factory = new UERC20Factory();
        token = UERC20(
            factory.createToken(
                "Test", "TEST", DECIMALS, INITIAL_BALANCE, recipient, abi.encode(tokenMetadata), bytes32("test")
            )
        );

        bytes memory data = decode(token);
        JsonTokenAllFields memory jsonToken = abi.decode(data, (JsonTokenAllFields));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
        assertEq(jsonToken.website, "https://example.com");
        assertEq(jsonToken.image, "Normal description\" , \"Website\": \"https://malicious.com");
    }

    function test_uerc20_tokenURI_descriptionWebsite() public {
        tokenMetadata = UERC20Metadata({description: "A test token", website: "https://example.com", image: ""});
        factory = new UERC20Factory();
        token = UERC20(
            factory.createToken(
                "Test", "TEST", DECIMALS, INITIAL_BALANCE, recipient, abi.encode(tokenMetadata), bytes32("test")
            )
        );

        bytes memory data = decode(token);
        JsonTokenDescriptionWebsite memory jsonToken = abi.decode(data, (JsonTokenDescriptionWebsite));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
        assertEq(jsonToken.website, "https://example.com");
    }

    function test_uerc20_tokenURI_descriptionImage() public {
        tokenMetadata =
            UERC20Metadata({description: "A test token", website: "", image: "https://example.com/image.png"});
        factory = new UERC20Factory();
        token = UERC20(
            factory.createToken(
                "Test", "TEST", DECIMALS, INITIAL_BALANCE, recipient, abi.encode(tokenMetadata), bytes32("test")
            )
        );

        bytes memory data = decode(token);
        JsonTokenDescriptionImage memory jsonToken = abi.decode(data, (JsonTokenDescriptionImage));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
        assertEq(jsonToken.image, "https://example.com/image.png");
    }

    function test_uerc20_tokenURI_websiteImage() public {
        tokenMetadata =
            UERC20Metadata({description: "", website: "https://example.com", image: "https://example.com/image.png"});
        factory = new UERC20Factory();
        token = UERC20(
            factory.createToken(
                "Test", "TEST", DECIMALS, INITIAL_BALANCE, recipient, abi.encode(tokenMetadata), bytes32("test")
            )
        );

        bytes memory data = decode(token);
        JsonTokenWebsiteImage memory jsonToken = abi.decode(data, (JsonTokenWebsiteImage));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.website, "https://example.com");
        assertEq(jsonToken.image, "https://example.com/image.png");
    }

    function test_uerc20_tokenURI_description() public {
        tokenMetadata = UERC20Metadata({description: "A test token", website: "", image: ""});
        factory = new UERC20Factory();
        token = UERC20(
            factory.createToken(
                "Test", "TEST", DECIMALS, INITIAL_BALANCE, recipient, abi.encode(tokenMetadata), bytes32("test")
            )
        );

        bytes memory data = decode(token);
        JsonTokenDescription memory jsonToken = abi.decode(data, (JsonTokenDescription));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
    }

    function test_uerc20_tokenURI_website() public {
        tokenMetadata = UERC20Metadata({description: "", website: "https://example.com", image: ""});
        factory = new UERC20Factory();
        token = UERC20(
            factory.createToken(
                "Test", "TEST", DECIMALS, INITIAL_BALANCE, recipient, abi.encode(tokenMetadata), bytes32("test")
            )
        );

        bytes memory data = decode(token);
        JsonTokenWebsite memory jsonToken = abi.decode(data, (JsonTokenWebsite));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.website, "https://example.com");
    }

    function test_uerc20_tokenURI_image() public {
        tokenMetadata = UERC20Metadata({description: "", website: "", image: "https://example.com/image.png"});
        factory = new UERC20Factory();
        token = UERC20(
            factory.createToken(
                "Test", "TEST", DECIMALS, INITIAL_BALANCE, recipient, abi.encode(tokenMetadata), bytes32("test")
            )
        );

        bytes memory data = decode(token);
        JsonTokenImage memory jsonToken = abi.decode(data, (JsonTokenImage));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.image, "https://example.com/image.png");
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_uerc20_permit_gas() public {
        uint256 privateKey = 1;
        address owner = vm.addr(privateKey);

        // Transfer tokens to owner for testing
        deal(address(token), owner, TRANSFER_AMOUNT);

        // Get the current nonce for the owner
        uint256 nonce = token.nonces(owner);
        uint256 deadline = type(uint256).max;

        // Calculate the permit digest
        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(abi.encode(permitTypehash, owner, bob, TRANSFER_AMOUNT, nonce, deadline))
            )
        );

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);

        // Execute permit with valid signature
        token.permit(owner, bob, TRANSFER_AMOUNT, deadline, v, r, s);
        vm.snapshotGasLastCall("UERC20 permit");

        // Verify that permit worked correctly
        assertEq(token.allowance(owner, bob), TRANSFER_AMOUNT);
    }

    function test_uerc20_domainSeparator() public view {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(token.name())),
                keccak256("1"),
                block.chainid,
                address(token)
            )
        );
        assertEq(domainSeparator, token.DOMAIN_SEPARATOR());
    }

    function decode(UERC20 _token) private view returns (bytes memory) {
        // The prefix length is calculated by converting the string to bytes and finding its length
        uint256 prefixLength = bytes("data:application/json;base64,").length;

        string memory uri = _token.tokenURI();
        // Convert the uri to bytes
        bytes memory uriBytes = bytes(uri);

        // Slice the uri to get only the base64-encoded part
        bytes memory base64Part = new bytes(uriBytes.length - prefixLength);

        for (uint256 i = 0; i < base64Part.length; i++) {
            base64Part[i] = uriBytes[i + prefixLength];
        }

        // Decode the base64-encoded part
        bytes memory decoded = Base64.decode(string(base64Part));
        string memory json = string(decoded);

        // decode json
        return vm.parseJson(json);
    }
}
