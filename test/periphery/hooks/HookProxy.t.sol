// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {HookTestBase} from "./HookTestBase.sol";
import {HookProxy, HookProxyLib} from "src/periphery/hooks/HookProxy.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract HookProxyDeployer {
    function deploy(IHooks impl, bytes32 salt) external returns (HookProxy) {
        return new HookProxy{salt: salt}(impl);
    }

    function preflight(address impl, bytes32 salt) external view {
        HookProxyLib.preflight(impl, salt);
    }

    function computeHookProxyAddress(address impl, bytes32 salt) external view returns (address) {
        return HookProxyLib.computeHookProxyAddress(impl, salt);
    }
}

contract MockHookProxyImpl {
    error UnexpectedBeforeInitialize();

    event BeforeInitializeForwarded(address sender, uint160 sqrtPriceX96);

    bool private immutable beforeInitializeRevert;

    constructor(bool _beforeInitializeRevert) {
        beforeInitializeRevert = _beforeInitializeRevert;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160 sqrtPriceX96) external returns (bytes4) {
        if (beforeInitializeRevert) revert UnexpectedBeforeInitialize();
        emit BeforeInitializeForwarded(sender, sqrtPriceX96);
        return IHooks.beforeInitialize.selector;
    }

    fallback() external payable {
        bytes memory ret = abi.encode(msg.sig, msg.sender, msg.value, keccak256(msg.data));
        assembly ("memory-safe") {
            return(add(ret, 0x20), mload(ret))
        }
    }
}

contract HookProxyTest is HookTestBase {
    HookProxyDeployer deployer;

    function setUp() public {
        deployer = new HookProxyDeployer();
    }

    function test_constructor_allowsImplementationZero() public {
        HookProxy proxy = _deployProxy(address(0));

        assertEq(address(proxy.impl()), address(0));
        assertEq(proxy.allowedInitializer(), address(deployer));
    }

    function test_constructor_revertsIfAddressPermissionsMismatch() public {
        MockHookProxyImpl impl = _deployImpl(Hooks.BEFORE_SWAP_FLAG, false);
        bytes memory args = abi.encode(IHooks(address(impl)));

        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(deployer), Hooks.BEFORE_INITIALIZE_FLAG, type(HookProxy).creationCode, args);

        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, hookAddr));
        deployer.deploy(IHooks(address(impl)), salt);
    }

    function test_constructor_setsImmutableArgs() public {
        MockHookProxyImpl impl = _deployImpl(0, false);
        HookProxy proxy = _deployProxy(address(impl));

        assertEq(address(proxy.impl()), address(impl));
        assertEq(proxy.allowedInitializer(), address(deployer));
    }

    function test_preflight_succeedsForMinedAddress() public {
        MockHookProxyImpl impl = _deployImpl(Hooks.BEFORE_SWAP_FLAG, false);
        (, bytes32 salt) = _findProxy(address(impl));

        deployer.preflight(address(impl), salt);
    }

    function test_preflight_revertsIfAddressPermissionsMismatch() public {
        MockHookProxyImpl impl = _deployImpl(Hooks.BEFORE_SWAP_FLAG, false);
        bytes memory args = abi.encode(IHooks(address(impl)));

        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(deployer), Hooks.BEFORE_INITIALIZE_FLAG, type(HookProxy).creationCode, args);

        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, hookAddr));
        deployer.preflight(address(impl), salt);
    }

    function test_computeHookProxyAddress_matchesMinedAddress() public {
        MockHookProxyImpl impl = _deployImpl(Hooks.BEFORE_SWAP_FLAG, false);
        (address hookAddr, bytes32 salt) = _findProxy(address(impl));

        assertEq(deployer.computeHookProxyAddress(address(impl), salt), hookAddr);
    }

    function test_fuzz_toPermissions_matchesFlags(uint16 rawFlags) public pure {
        uint160 flags = _normalizeFlags(uint160(rawFlags));
        Hooks.Permissions memory permissions = HookProxyLib.toPermissions(flags);

        assertEq(permissions.beforeInitialize, flags & Hooks.BEFORE_INITIALIZE_FLAG != 0);
        assertEq(permissions.afterInitialize, flags & Hooks.AFTER_INITIALIZE_FLAG != 0);
        assertEq(permissions.beforeAddLiquidity, flags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0);
        assertEq(permissions.afterAddLiquidity, flags & Hooks.AFTER_ADD_LIQUIDITY_FLAG != 0);
        assertEq(permissions.beforeRemoveLiquidity, flags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0);
        assertEq(permissions.afterRemoveLiquidity, flags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG != 0);
        assertEq(permissions.beforeSwap, flags & Hooks.BEFORE_SWAP_FLAG != 0);
        assertEq(permissions.afterSwap, flags & Hooks.AFTER_SWAP_FLAG != 0);
        assertEq(permissions.beforeDonate, flags & Hooks.BEFORE_DONATE_FLAG != 0);
        assertEq(permissions.afterDonate, flags & Hooks.AFTER_DONATE_FLAG != 0);
        assertEq(permissions.beforeSwapReturnDelta, flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0);
        assertEq(permissions.afterSwapReturnDelta, flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0);
        assertEq(permissions.afterAddLiquidityReturnDelta, flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0);
        assertEq(
            permissions.afterRemoveLiquidityReturnDelta, flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0
        );
    }

    function test_fuzz_beforeInitialize_revertsIfNotAllowedInitializer(address notInitializer, uint160 sqrtPriceX96)
        public
    {
        MockHookProxyImpl impl = _deployImpl(0, true);
        HookProxy proxy = _deployProxy(address(impl));
        PoolKey memory key = _defaultPoolKey(address(proxy));

        vm.assume(notInitializer != address(deployer));
        vm.expectRevert(
            abi.encodeWithSelector(HookProxy.InvalidInitializer.selector, notInitializer, address(deployer))
        );
        proxy.beforeInitialize(notInitializer, key, sqrtPriceX96);
    }

    function test_fuzz_beforeInitialize_returnsSelectorIfImplDoesNotImplement(uint160 sqrtPriceX96) public {
        MockHookProxyImpl impl = _deployImpl(0, true);
        HookProxy proxy = _deployProxy(address(impl));
        PoolKey memory key = _defaultPoolKey(address(proxy));

        bytes4 result = proxy.beforeInitialize(address(deployer), key, sqrtPriceX96);

        assertEq(result, IHooks.beforeInitialize.selector);
    }

    function test_fuzz_beforeInitialize_delegatesIfImplImplements(uint160 sqrtPriceX96) public {
        MockHookProxyImpl impl = _deployImpl(Hooks.BEFORE_INITIALIZE_FLAG, false);
        HookProxy proxy = _deployProxy(address(impl));
        PoolKey memory key = _defaultPoolKey(address(proxy));

        vm.expectEmit(address(proxy));
        emit MockHookProxyImpl.BeforeInitializeForwarded(address(deployer), sqrtPriceX96);

        bytes4 result = proxy.beforeInitialize(address(deployer), key, sqrtPriceX96);

        assertEq(result, IHooks.beforeInitialize.selector);
    }

    function test_fuzz_forwardsAllSelectors(bytes4 selector, bytes32 payload, address caller, uint96 value) public {
        vm.assume(!_isProxySelector(selector));
        MockHookProxyImpl impl = _deployImpl(0, false);
        HookProxy proxy = _deployProxy(address(impl));
        bytes memory data = abi.encodePacked(selector, payload);

        vm.deal(caller, value);
        vm.prank(caller);
        (bool success, bytes memory ret) = address(proxy).call{value: value}(data);

        assertTrue(success);
        (bytes4 forwardedSelector, address forwardedSender, uint256 forwardedValue, bytes32 forwardedHash) =
            abi.decode(ret, (bytes4, address, uint256, bytes32));
        assertEq(forwardedSelector, selector);
        assertEq(forwardedSender, caller);
        assertEq(forwardedValue, value);
        assertEq(forwardedHash, keccak256(data));
    }

    function _deployImpl(uint160 flags, bool beforeInitializeRevert) internal returns (MockHookProxyImpl impl) {
        flags = _normalizeFlags(flags);
        bytes memory args = abi.encode(beforeInitializeRevert);
        (, bytes32 salt) = HookMiner.find(address(this), flags, type(MockHookProxyImpl).creationCode, args);
        impl = new MockHookProxyImpl{salt: salt}(beforeInitializeRevert);
        assertEq(uint160(address(impl)) & HookMiner.FLAG_MASK, flags);
    }

    function _deployProxy(address impl) internal returns (HookProxy proxy) {
        (address hookAddr, bytes32 salt) = _findProxy(impl);

        proxy = deployer.deploy(IHooks(impl), salt);

        assertEq(address(proxy), hookAddr);
        assertEq(
            uint160(address(proxy)) & HookMiner.FLAG_MASK,
            (uint160(impl) & HookMiner.FLAG_MASK) | Hooks.BEFORE_INITIALIZE_FLAG
        );
    }

    function _findProxy(address impl) internal view returns (address hookAddr, bytes32 salt) {
        uint160 flags = (uint160(impl) & HookMiner.FLAG_MASK) | Hooks.BEFORE_INITIALIZE_FLAG;
        return HookMiner.find(address(deployer), flags, type(HookProxy).creationCode, abi.encode(IHooks(impl)));
    }

    function _isProxySelector(bytes4 selector) internal pure returns (bool) {
        return selector == HookProxy.beforeInitialize.selector || selector == bytes4(keccak256("impl()"))
            || selector == bytes4(keccak256("allowedInitializer()"));
    }

    function _normalizeFlags(uint160 flags) internal pure returns (uint160) {
        flags = flags & HookMiner.FLAG_MASK;
        if (flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0) flags |= Hooks.AFTER_SWAP_FLAG;
        if (flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0) flags |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        return flags;
    }
}
