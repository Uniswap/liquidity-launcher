// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {USUPERC20} from "../../../src/token-factories/uerc20-factory/tokens/USUPERC20.sol";
import {USUPERC20Factory} from "../../../src/token-factories/uerc20-factory/factories/USUPERC20Factory.sol";
import {UERC20Metadata} from "../../../src/token-factories/uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC7802, IERC165} from "@optimism/interfaces/L2/IERC7802.sol";
import {Base64} from "./libraries/base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract USUPERC20Test is Test {
    using Base64 for string;
    using Strings for address;

    address constant SUPERCHAIN_ERC20_BRIDGE = 0x4200000000000000000000000000000000000028;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint256 constant INITIAL_BALANCE = 5e18;
    uint256 constant TRANSFER_AMOUNT = 1e18;
    uint8 constant DECIMALS = 18;

    USUPERC20 token;
    USUPERC20Factory factory;
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

    event CrosschainMint(address indexed to, uint256 amount, address indexed sender);
    event CrosschainBurn(address indexed from, uint256 amount, address indexed sender);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        tokenMetadata = UERC20Metadata({
            description: "A test token",
            website: "https://example.com",
            image: "https://example.com/image.png"
        });
        factory = new USUPERC20Factory();
        token = USUPERC20(
            factory.createToken(
                "Test",
                "TEST",
                DECIMALS,
                INITIAL_BALANCE,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32(0)
            )
        );
    }

    function test_usuperc20_data_succeeds() public view {
        assertEq(token.homeChainId(), block.chainid);
        assertEq(token.creator(), address(this));
        assertEq(token.graffiti(), bytes32(0));
    }

    function test_usuperc20_crosschainMint_succeeds() public {
        vm.expectEmit(true, false, true, true);
        emit CrosschainMint(bob, TRANSFER_AMOUNT, SUPERCHAIN_ERC20_BRIDGE);
        vm.startPrank(SUPERCHAIN_ERC20_BRIDGE);
        token.crosschainMint(bob, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
        assertEq(token.totalSupply(), INITIAL_BALANCE + TRANSFER_AMOUNT);
        token.crosschainMint(bob, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT * 2);
    }

    function test_usuperc20_fuzz_crosschainMint_succeeds(address to, uint256 amount) public {
        vm.assume(to != address(0));
        // Prevent overflow
        amount = bound(amount, 0, type(uint256).max - token.totalSupply());

        uint256 totalSupplyBefore = token.totalSupply();
        uint256 toBalanceBefore = token.balanceOf(to);

        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), to, amount);

        vm.expectEmit(true, false, true, true);
        emit CrosschainMint(to, amount, SUPERCHAIN_ERC20_BRIDGE);

        vm.startPrank(SUPERCHAIN_ERC20_BRIDGE);
        token.crosschainMint(to, amount);

        assertEq(token.totalSupply(), totalSupplyBefore + amount);
        assertEq(token.balanceOf(to), toBalanceBefore + amount);
    }

    function test_usuperc20_crosschainMint_revertsWithNotSuperchainERC20Bridge() public {
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(USUPERC20.NotSuperchainTokenBridge.selector, bob, SUPERCHAIN_ERC20_BRIDGE)
        );
        token.crosschainMint(bob, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), INITIAL_BALANCE);
    }

    function test_usuperc20_crosschainMint_revertsWithRecipientCannotBeZeroAddress() public {
        vm.prank(SUPERCHAIN_ERC20_BRIDGE);
        vm.expectRevert(abi.encodeWithSelector(USUPERC20.RecipientCannotBeZeroAddress.selector));
        token.crosschainMint(address(0), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), INITIAL_BALANCE);
    }

    function test_usuperc20_fuzz_crosschainMint_revertsWithNotSuperchainERC20Bridge(
        address caller,
        address to,
        uint256 amount
    ) public {
        vm.assume(caller != SUPERCHAIN_ERC20_BRIDGE);

        vm.expectRevert(
            abi.encodeWithSelector(USUPERC20.NotSuperchainTokenBridge.selector, caller, SUPERCHAIN_ERC20_BRIDGE)
        );

        vm.prank(caller);
        token.crosschainMint(to, amount);
    }

    function test_usuperc20_crosschainBurn_succeeds() public {
        deal(address(token), bob, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
        vm.expectEmit(true, false, true, true);
        emit CrosschainBurn(bob, TRANSFER_AMOUNT, SUPERCHAIN_ERC20_BRIDGE);
        vm.prank(SUPERCHAIN_ERC20_BRIDGE);
        token.crosschainBurn(bob, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_usuperc20_fuzz_crosschainBurn_succeeds(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());

        uint256 totalSupplyBefore = token.totalSupply();
        uint256 recipientBalanceBefore = token.balanceOf(recipient);

        vm.expectEmit(true, true, false, true);
        emit Transfer(recipient, address(0), amount);

        vm.expectEmit(true, false, true, true);
        emit CrosschainBurn(recipient, amount, SUPERCHAIN_ERC20_BRIDGE);

        vm.startPrank(SUPERCHAIN_ERC20_BRIDGE);
        token.crosschainBurn(recipient, amount);

        assertEq(token.totalSupply(), totalSupplyBefore - amount);
        assertEq(token.balanceOf(recipient), recipientBalanceBefore - amount);
    }

    function test_usuperc20_crosschainBurn_revertsWithNotSuperchainERC20Bridge() public {
        deal(address(token), bob, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(USUPERC20.NotSuperchainTokenBridge.selector, bob, SUPERCHAIN_ERC20_BRIDGE)
        );
        token.crosschainBurn(bob, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
    }

    function test_usuperc20_fuzz_crosschainBurn_revertsWithNotSuperchainERC20Bridge(
        address caller,
        address from,
        uint256 amount
    ) public {
        vm.assume(caller != SUPERCHAIN_ERC20_BRIDGE);

        vm.expectRevert(
            abi.encodeWithSelector(USUPERC20.NotSuperchainTokenBridge.selector, caller, SUPERCHAIN_ERC20_BRIDGE)
        );

        vm.prank(caller);
        token.crosschainBurn(from, amount);
    }

    function test_usuperc20_supportsInterface() public view {
        assertTrue(bytes4(0x01ffc9a7) == type(IERC165).interfaceId);
        assertTrue(token.supportsInterface(0x01ffc9a7)); // IERC165
        assertTrue(bytes4(0x33331994) == type(IERC7802).interfaceId);
        assertTrue(token.supportsInterface(0x33331994)); // IERC7802
        assertTrue(bytes4(0x36372b07) == type(IERC20).interfaceId);
        assertTrue(token.supportsInterface(0x36372b07)); // IERC20
        assertTrue(bytes4(0x9d8ff7da) == type(IERC20Permit).interfaceId);
        assertTrue(token.supportsInterface(0x9d8ff7da)); // IERC20Permit
    }

    function test_usuperc20_fuzz_supportsInterface(bytes4 interfaceId) public view {
        vm.assume(interfaceId != type(IERC165).interfaceId);
        vm.assume(interfaceId != type(IERC7802).interfaceId);
        vm.assume(interfaceId != type(IERC20).interfaceId);
        vm.assume(interfaceId != type(IERC20Permit).interfaceId);
        assertFalse(token.supportsInterface(interfaceId));
    }

    function test_usuperc20_permit2CanTransferWithoutAllowance() public {
        vm.startPrank(PERMIT2);
        token.transferFrom(recipient, bob, TRANSFER_AMOUNT);
        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(recipient), INITIAL_BALANCE - TRANSFER_AMOUNT);
        vm.stopPrank();
    }

    function test_usuperc20_nonPermit2CannotTransferWithoutAllowance() public {
        vm.startPrank(bob);
        vm.expectRevert();
        token.transferFrom(recipient, bob, TRANSFER_AMOUNT);
        vm.stopPrank();
    }

    function test_usuperc20_nonPermit2CanTransferWithAllowance() public {
        vm.prank(recipient);
        token.approve(bob, TRANSFER_AMOUNT);

        vm.prank(bob);
        token.transferFrom(recipient, bob, TRANSFER_AMOUNT);

        assertEq(token.balanceOf(bob), TRANSFER_AMOUNT);
        assertEq(token.balanceOf(recipient), INITIAL_BALANCE - TRANSFER_AMOUNT);
        assertEq(token.allowance(recipient, bob), 0);
    }

    function test_usuperc20_permit2InfiniteAllowance() public view {
        assertEq(token.allowance(recipient, PERMIT2), type(uint256).max);
    }

    function test_usuperc20_nameSymbolDecimalsTotalSupply() public view {
        assertEq(token.name(), "Test");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), DECIMALS);
        assertEq(token.totalSupply(), INITIAL_BALANCE);
    }

    function test_usuperc20_tokenURI_allFields() public view {
        bytes memory data = decode(token);
        JsonTokenAllFields memory jsonToken = abi.decode(data, (JsonTokenAllFields));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
        assertEq(jsonToken.website, "https://example.com");
        assertEq(jsonToken.image, "https://example.com/image.png");
    }

    function test_usuperc20_tokenURI_maliciousInjectionDetected() public {
        tokenMetadata = UERC20Metadata({
            description: "A test token",
            website: "https://example.com",
            image: "Normal description\" , \"Website\": \"https://malicious.com"
        });
        factory = new USUPERC20Factory();
        token = USUPERC20(
            factory.createToken(
                "Test",
                "TEST",
                DECIMALS,
                INITIAL_BALANCE,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32(0)
            )
        );

        bytes memory data = decode(token);
        JsonTokenAllFields memory jsonToken = abi.decode(data, (JsonTokenAllFields));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
        assertEq(jsonToken.website, "https://example.com");
        assertEq(jsonToken.image, "Normal description\" , \"Website\": \"https://malicious.com");
    }

    function test_usuperc20_tokenURI_descriptionWebsite() public {
        tokenMetadata = UERC20Metadata({description: "A test token", website: "https://example.com", image: ""});
        factory = new USUPERC20Factory();
        token = USUPERC20(
            factory.createToken(
                "Test",
                "TEST",
                DECIMALS,
                INITIAL_BALANCE,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32(0)
            )
        );

        bytes memory data = decode(token);
        JsonTokenDescriptionWebsite memory jsonToken = abi.decode(data, (JsonTokenDescriptionWebsite));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
        assertEq(jsonToken.website, "https://example.com");
    }

    function test_usuperc20_tokenURI_descriptionImage() public {
        tokenMetadata =
            UERC20Metadata({description: "A test token", website: "", image: "https://example.com/image.png"});
        factory = new USUPERC20Factory();
        token = USUPERC20(
            factory.createToken(
                "Test",
                "TEST",
                DECIMALS,
                INITIAL_BALANCE,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32(0)
            )
        );

        bytes memory data = decode(token);
        JsonTokenDescriptionImage memory jsonToken = abi.decode(data, (JsonTokenDescriptionImage));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
        assertEq(jsonToken.image, "https://example.com/image.png");
    }

    function test_usuperc20_tokenURI_websiteImage() public {
        tokenMetadata =
            UERC20Metadata({description: "", website: "https://example.com", image: "https://example.com/image.png"});
        factory = new USUPERC20Factory();
        token = USUPERC20(
            factory.createToken(
                "Test",
                "TEST",
                DECIMALS,
                INITIAL_BALANCE,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32(0)
            )
        );

        bytes memory data = decode(token);
        JsonTokenWebsiteImage memory jsonToken = abi.decode(data, (JsonTokenWebsiteImage));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.website, "https://example.com");
        assertEq(jsonToken.image, "https://example.com/image.png");
    }

    function test_usuperc20_tokenURI_description() public {
        tokenMetadata = UERC20Metadata({description: "A test token", website: "", image: ""});
        factory = new USUPERC20Factory();
        token = USUPERC20(
            factory.createToken(
                "Test",
                "TEST",
                DECIMALS,
                INITIAL_BALANCE,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32(0)
            )
        );

        bytes memory data = decode(token);
        JsonTokenDescription memory jsonToken = abi.decode(data, (JsonTokenDescription));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.description, "A test token");
    }

    function test_usuperc20_tokenURI_website() public {
        tokenMetadata = UERC20Metadata({description: "", website: "https://example.com", image: ""});
        factory = new USUPERC20Factory();
        token = USUPERC20(
            factory.createToken(
                "Test",
                "TEST",
                DECIMALS,
                INITIAL_BALANCE,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32(0)
            )
        );

        bytes memory data = decode(token);
        JsonTokenWebsite memory jsonToken = abi.decode(data, (JsonTokenWebsite));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.website, "https://example.com");
    }

    function test_usuperc20_tokenURI_image() public {
        tokenMetadata = UERC20Metadata({description: "", website: "", image: "https://example.com/image.png"});
        factory = new USUPERC20Factory();
        token = USUPERC20(
            factory.createToken(
                "Test",
                "TEST",
                DECIMALS,
                INITIAL_BALANCE,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32(0)
            )
        );

        bytes memory data = decode(token);
        JsonTokenImage memory jsonToken = abi.decode(data, (JsonTokenImage));

        // Parse JSON to extract individual fields
        assertEq(jsonToken.image, "https://example.com/image.png");
    }

    function decode(USUPERC20 _token) private view returns (bytes memory) {
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

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_usuperc20_crosschainMint_succeeds_gas() public {
        vm.startPrank(SUPERCHAIN_ERC20_BRIDGE);
        token.crosschainMint(bob, TRANSFER_AMOUNT);
        vm.snapshotGasLastCall("crosschainMint: first mint");
        token.crosschainMint(bob, TRANSFER_AMOUNT);
        vm.snapshotGasLastCall("crosschainMint: second mint");
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_usuperc20_crosschainBurn_succeeds_gas() public {
        deal(address(token), bob, TRANSFER_AMOUNT);
        vm.prank(SUPERCHAIN_ERC20_BRIDGE);
        token.crosschainBurn(bob, TRANSFER_AMOUNT);
        vm.snapshotGasLastCall("crosschainBurn");
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_usuperc20_permit_gas() public {
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
        vm.snapshotGasLastCall("USUPERC20 permit");

        // Verify that permit worked correctly
        assertEq(token.allowance(owner, bob), TRANSFER_AMOUNT);
    }

    function test_usuperc20_domainSeparator() public view {
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
}
