// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {UERC20Factory} from "../../../src/token-factories/uerc20-factory/factories/UERC20Factory.sol";
import {UERC20} from "../../../src/token-factories/uerc20-factory/tokens/UERC20.sol";
import {UERC20Metadata} from "../../../src/token-factories/uerc20-factory/libraries/UERC20MetadataLibrary.sol";
import {ITokenFactory} from "../../../src/token-factories/uerc20-factory/interfaces/ITokenFactory.sol";

contract UERC20FactoryTest is Test {
    UERC20Factory public factory;
    UERC20Metadata public tokenMetadata;
    address recipient = makeAddr("recipient");
    string name = "Test Token";
    string symbol = "TOKEN";
    uint8 decimals = 18;
    address bob = makeAddr("bob");

    event TokenCreated(address tokenAddress);

    function setUp() public {
        factory = new UERC20Factory();
        tokenMetadata = UERC20Metadata({
            description: "A test token",
            website: "https://example.com",
            image: "https://example.com/image.png"
        });
    }

    function test_create_succeeds_withMint() public {
        UERC20 token =
            UERC20(factory.createToken(name, symbol, decimals, 1e18, recipient, abi.encode(tokenMetadata), bytes32(0)));

        assert(address(token) != address(0));

        assertEq(token.name(), name);
        assertEq(token.symbol(), symbol);
        assertEq(token.decimals(), decimals);
        assertEq(token.totalSupply(), 1e18);
        assertEq(token.balanceOf(recipient), 1e18);
    }

    function test_create_uerc20_revertsWithRecipientCannotBeZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.RecipientCannotBeZeroAddress.selector));
        factory.createToken(name, symbol, decimals, 1e18, address(0), abi.encode(tokenMetadata), bytes32(0));
    }

    function test_create_uerc20_revertsWithTotalSupplyCannotBeZero() public {
        vm.expectRevert(abi.encodeWithSelector(ITokenFactory.TotalSupplyCannotBeZero.selector));
        factory.createToken(name, symbol, decimals, 0, recipient, abi.encode(tokenMetadata), bytes32(0));
    }

    function test_getUERC20Address_succeeds() public {
        // Calculate expected address using getUERC20Address and verify against actual deployment
        address expectedAddress = factory.getUERC20Address(name, symbol, decimals, address(this), bytes32(0));

        UERC20 token =
            UERC20(factory.createToken(name, symbol, decimals, 1e18, recipient, abi.encode(tokenMetadata), bytes32(0)));

        assertEq(address(token), expectedAddress);
    }

    function test_create_succeeds_withEventEmitted() public {
        address tokenAddress = factory.getUERC20Address(name, symbol, decimals, address(this), bytes32(0));

        vm.expectEmit(true, true, true, true);
        emit TokenCreated(tokenAddress);
        factory.createToken(name, symbol, decimals, 1e18, recipient, abi.encode(tokenMetadata), bytes32(0));
    }

    function test_create_succeeds_withDifferentAddresses() public {
        // Deploy first token
        UERC20 token =
            UERC20(factory.createToken(name, symbol, decimals, 1e18, recipient, abi.encode(tokenMetadata), bytes32(0)));

        // Deploy second token with different symbol
        string memory differentSymbol = "TOKEN2";
        address expectedNewAddress =
            factory.getUERC20Address(name, differentSymbol, decimals, address(this), bytes32(0));
        UERC20 newToken = UERC20(
            factory.createToken(name, differentSymbol, decimals, 1e18, recipient, abi.encode(tokenMetadata), bytes32(0))
        );

        assertEq(address(newToken), expectedNewAddress);
        assertNotEq(address(newToken), address(token));
    }

    function test_create_revertsWithCreateCollision() public {
        factory.createToken(name, symbol, decimals, 1e18, recipient, abi.encode(tokenMetadata), bytes32(0));

        vm.expectRevert();
        factory.createToken(name, symbol, decimals, 1e18, recipient, abi.encode(tokenMetadata), bytes32(0));
    }

    function test_bytecodeSize_uerc20factory() public {
        vm.snapshotValue("UERC20 Factory bytecode size", address(factory).code.length);
    }

    function test_bytecodeSize_uerc20() public {
        UERC20 token =
            UERC20(factory.createToken(name, symbol, decimals, 1e18, recipient, abi.encode(tokenMetadata), bytes32(0)));
        vm.snapshotValue("UERC20 bytecode size", address(token).code.length);
    }

    function test_initcodeHash_uerc20() public {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(UERC20).creationCode));
        vm.snapshotValue("UERC20 initcode hash", uint256(initCodeHash));
    }

    /// forge-config: default.isolate = true
    /// forge-config: ci.isolate = true
    function test_create_uerc20_succeeds_withMint_gas() public {
        UERC20(factory.createToken(name, symbol, decimals, 1e18, recipient, abi.encode(tokenMetadata), bytes32(0)));
        vm.snapshotGasLastCall("deploy new UERC20");
    }
}
