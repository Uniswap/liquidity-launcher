// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {USUPERC20Factory} from "../../../src/token-factories/uerc20-factory/factories/USUPERC20Factory.sol";
import {USUPERC20} from "../../../src/token-factories/uerc20-factory/tokens/USUPERC20.sol";
import {UERC20Metadata} from "../../../src/token-factories/uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {IUSUPERC20Factory} from "../../../src/token-factories/uerc20-factory/interfaces/IUSUPERC20Factory.sol";
import {ITokenFactory} from "../../../src/token-factories/uerc20-factory/interfaces/ITokenFactory.sol";

contract USUPERC20FactoryTest is Test {
    USUPERC20Factory public factory;
    UERC20Metadata public tokenMetadata;
    address recipient = makeAddr("recipient");
    string name = "Test Token";
    string symbol = "TOKEN";
    uint8 decimals = 18;
    address bob = makeAddr("bob");

    event TokenCreated(address tokenAddress);

    function setUp() public {
        factory = new USUPERC20Factory();
        tokenMetadata = UERC20Metadata({
            description: "A test token",
            website: "https://example.com",
            image: "https://example.com/image.png"
        });
    }

    function test_create_succeeds_withMint() public {
        USUPERC20 token = USUPERC20(
            factory.createToken(
                name,
                symbol,
                decimals,
                1e18,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32("test")
            )
        );

        assert(address(token) != address(0));

        assertEq(token.name(), name);
        assertEq(token.symbol(), symbol);
        assertEq(token.decimals(), decimals);
        assertEq(token.totalSupply(), 1e18);
        assertEq(token.balanceOf(recipient), 1e18);
    }

    function test_create_usuperc20_revertsWithNotCreator() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IUSUPERC20Factory.NotCreator.selector, bob, address(this)));
        factory.createToken(
            name,
            symbol,
            decimals,
            1e18,
            recipient,
            abi.encode(block.chainid, address(this), tokenMetadata),
            bytes32("test")
        );
    }

    function test_create_usuperc20_revertsWithRecipientCannotBeZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.RecipientCannotBeZeroAddress.selector));
        factory.createToken(
            name,
            symbol,
            decimals,
            1e18,
            address(0),
            abi.encode(block.chainid, address(this), tokenMetadata),
            bytes32(0)
        );
    }

    function test_create_usuperc20_revertsWithTotalSupplyCannotBeZero() public {
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.TotalSupplyCannotBeZero.selector));
        factory.createToken(
            name, symbol, decimals, 0, recipient, abi.encode(block.chainid, address(this), tokenMetadata), bytes32(0)
        );
    }

    function test_create_succeeds_withoutMintOnDifferentChain() public {
        USUPERC20 token = USUPERC20(
            factory.createToken(
                name,
                symbol,
                decimals,
                1e18,
                recipient,
                abi.encode(block.chainid + 1, address(this), tokenMetadata),
                bytes32("test")
            )
        ); // the home chain of this token is different than the current chain

        assert(address(token) != address(0));

        assertEq(token.name(), name);
        assertEq(token.symbol(), symbol);
        assertEq(token.decimals(), decimals);

        // no tokens have been minted because the current chain is not the token's home chain
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_create_succeeds_withoutMintOnDifferentChainAndNotCreator() public {
        vm.prank(bob);
        USUPERC20 token = USUPERC20(
            factory.createToken(
                name,
                symbol,
                decimals,
                1e18,
                recipient,
                abi.encode(block.chainid + 1, address(this), tokenMetadata),
                bytes32("test")
            )
        ); // the home chain of this token is different than the current chain

        assert(address(token) != address(0));

        assertEq(token.name(), name);
        assertEq(token.symbol(), symbol);
        assertEq(token.decimals(), decimals);

        // no tokens have been minted because the current chain is not the token's home chain
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_getUSUPERC20Address_succeeds() public {
        // Calculate expected address using getUSUPERC20Address and verify against actual deployment
        address expectedAddress =
            factory.getUSUPERC20Address(name, symbol, decimals, block.chainid, address(this), bytes32("test"));

        USUPERC20 token = USUPERC20(
            factory.createToken(
                name,
                symbol,
                decimals,
                1e18,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32("test")
            )
        );

        assertEq(address(token), expectedAddress);
    }

    function test_create_succeeds_withEventEmitted() public {
        address tokenAddress =
            factory.getUSUPERC20Address(name, symbol, decimals, block.chainid, address(this), bytes32("test"));

        vm.expectEmit(true, true, true, true);
        emit TokenCreated(tokenAddress);
        factory.createToken(
            name,
            symbol,
            decimals,
            1e18,
            recipient,
            abi.encode(block.chainid, address(this), tokenMetadata),
            bytes32("test")
        );
    }

    function test_create_succeeds_withDifferentAddresses() public {
        // Deploy first token
        USUPERC20 token = USUPERC20(
            factory.createToken(
                name,
                symbol,
                decimals,
                1e18,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32("test")
            )
        );

        // Deploy second token with different symbol
        string memory differentSymbol = "TOKEN2";
        address expectedNewAddress =
            factory.getUSUPERC20Address(name, differentSymbol, decimals, block.chainid, address(this), bytes32("test"));
        USUPERC20 newToken = USUPERC20(
            factory.createToken(
                name,
                differentSymbol,
                decimals,
                1e18,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32("test")
            )
        );

        assertEq(address(newToken), expectedNewAddress);
        assertNotEq(address(newToken), address(token));
    }

    function test_create_revertsWithCreateCollision() public {
        factory.createToken(
            name,
            symbol,
            decimals,
            1e18,
            recipient,
            abi.encode(block.chainid, address(this), tokenMetadata),
            bytes32("test")
        );

        vm.expectRevert();
        factory.createToken(
            name,
            symbol,
            decimals,
            1e18,
            recipient,
            abi.encode(block.chainid, address(this), tokenMetadata),
            bytes32("test")
        );
    }

    function test_create_metadataClearedOnDifferentChain() public {
        USUPERC20 token = USUPERC20(
            factory.createToken(
                name,
                symbol,
                decimals,
                1e18,
                recipient,
                abi.encode(block.chainid + 1, address(this), tokenMetadata),
                bytes32("test")
            )
        );

        (string memory description, string memory website, string memory image) = token.metadata();
        assertEq(description, "");
        assertEq(image, "");
        assertEq(website, "");
    }

    function test_bytecodeSize_usuperc20factory() public {
        vm.snapshotValue("USUPERC20 Factory bytecode size", address(factory).code.length);
    }

    function test_bytecodeSize_usuperc20() public {
        USUPERC20 token = USUPERC20(
            factory.createToken(
                name,
                symbol,
                decimals,
                1e18,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32("test")
            )
        );
        vm.snapshotValue("USUPERC20 bytecode size", address(token).code.length);
    }

    function test_initcodeHash_usuperc20() public {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(USUPERC20).creationCode));
        vm.snapshotValue("USUPERC20 initcode hash", uint256(initCodeHash));
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_create_usuperc20_succeeds_withMint_gas() public {
        USUPERC20(
            factory.createToken(
                name,
                symbol,
                decimals,
                1e18,
                recipient,
                abi.encode(block.chainid, address(this), tokenMetadata),
                bytes32("test")
            )
        );
        vm.snapshotGasLastCall("deploy new USUPERC20");
    }
}
