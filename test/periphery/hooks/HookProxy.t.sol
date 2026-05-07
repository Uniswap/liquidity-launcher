// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {HookTestBase} from "./HookTestBase.sol";
import {HookProxy} from "src/periphery/hooks/HookProxy.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

contract MockHookProxyImpl {
    error PermissionsRevert();
    error UnexpectedBeforeInitialize();

    event BeforeInitializeForwarded(address sender, uint160 sqrtPriceX96);

    uint160 private immutable flags;
    bool private immutable permissionsRevert;
    bool private immutable beforeInitializeRevert;

    constructor(uint160 _flags, bool _permissionsRevert, bool _beforeInitializeRevert) {
        flags = _flags;
        permissionsRevert = _permissionsRevert;
        beforeInitializeRevert = _beforeInitializeRevert;
    }

    function getHookPermissions() external view returns (Hooks.Permissions memory) {
        if (permissionsRevert) revert PermissionsRevert();
        return _permissionsFromFlags(flags);
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

    function _permissionsFromFlags(uint160 _flags) private pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: _flags & Hooks.BEFORE_INITIALIZE_FLAG != 0,
            afterInitialize: _flags & Hooks.AFTER_INITIALIZE_FLAG != 0,
            beforeAddLiquidity: _flags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0,
            afterAddLiquidity: _flags & Hooks.AFTER_ADD_LIQUIDITY_FLAG != 0,
            beforeRemoveLiquidity: _flags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0,
            afterRemoveLiquidity: _flags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG != 0,
            beforeSwap: _flags & Hooks.BEFORE_SWAP_FLAG != 0,
            afterSwap: _flags & Hooks.AFTER_SWAP_FLAG != 0,
            beforeDonate: _flags & Hooks.BEFORE_DONATE_FLAG != 0,
            afterDonate: _flags & Hooks.AFTER_DONATE_FLAG != 0,
            beforeSwapReturnDelta: _flags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0,
            afterSwapReturnDelta: _flags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0,
            afterAddLiquidityReturnDelta: _flags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0,
            afterRemoveLiquidityReturnDelta: _flags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0
        });
    }
}

contract HookProxyTest is HookTestBase {
    function test_constructor_revertsIfImplementationZero() public {
        vm.expectRevert(abi.encodeWithSelector(HookProxy.InvalidImplementation.selector));
        new HookProxy(address(0), strategy);
    }

    function test_constructor_revertsIfStrategyZero() public {
        MockHookProxyImpl impl = new MockHookProxyImpl(0, false, false);

        vm.expectRevert(abi.encodeWithSelector(HookProxy.InvalidStrategy.selector));
        new HookProxy(address(impl), address(0));
    }

    function test_constructor_revertsIfAddressPermissionsMismatch() public {
        uint160 implFlags = Hooks.BEFORE_SWAP_FLAG;
        MockHookProxyImpl impl = new MockHookProxyImpl(implFlags, false, false);
        bytes memory args = abi.encode(address(impl), strategy);

        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), Hooks.BEFORE_INITIALIZE_FLAG, type(HookProxy).creationCode, args);

        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, hookAddr));
        new HookProxy{salt: salt}(address(impl), strategy);
    }

    function test_constructor_revertsIfImplementationPermissionsRevert() public {
        MockHookProxyImpl impl = new MockHookProxyImpl(0, true, false);
        bytes memory args = abi.encode(address(impl), strategy);

        (, bytes32 salt) =
            HookMiner.find(address(this), Hooks.BEFORE_INITIALIZE_FLAG, type(HookProxy).creationCode, args);

        vm.expectRevert(abi.encodeWithSelector(HookProxy.InvalidImplementation.selector));
        new HookProxy{salt: salt}(address(impl), strategy);
    }

    function test_constructor_setsImmutableArgs() public {
        MockHookProxyImpl impl = new MockHookProxyImpl(0, false, false);
        HookProxy proxy = _deployProxy(address(impl), Hooks.BEFORE_INITIALIZE_FLAG);

        assertEq(proxy.impl(), address(impl));
        assertEq(proxy.strategy(), strategy);
    }

    function test_fuzz_getHookPermissions_addsBeforeInitialize(uint16 rawFlags) public {
        uint160 implFlags = _normalizeFlags(uint160(rawFlags));
        MockHookProxyImpl impl = new MockHookProxyImpl(implFlags, false, false);
        HookProxy proxy = _deployProxy(address(impl), implFlags | Hooks.BEFORE_INITIALIZE_FLAG);

        Hooks.Permissions memory permissions = proxy.getHookPermissions();

        assertTrue(permissions.beforeInitialize);
        assertEq(permissions.afterInitialize, implFlags & Hooks.AFTER_INITIALIZE_FLAG != 0);
        assertEq(permissions.beforeAddLiquidity, implFlags & Hooks.BEFORE_ADD_LIQUIDITY_FLAG != 0);
        assertEq(permissions.afterAddLiquidity, implFlags & Hooks.AFTER_ADD_LIQUIDITY_FLAG != 0);
        assertEq(permissions.beforeRemoveLiquidity, implFlags & Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG != 0);
        assertEq(permissions.afterRemoveLiquidity, implFlags & Hooks.AFTER_REMOVE_LIQUIDITY_FLAG != 0);
        assertEq(permissions.beforeSwap, implFlags & Hooks.BEFORE_SWAP_FLAG != 0);
        assertEq(permissions.afterSwap, implFlags & Hooks.AFTER_SWAP_FLAG != 0);
        assertEq(permissions.beforeDonate, implFlags & Hooks.BEFORE_DONATE_FLAG != 0);
        assertEq(permissions.afterDonate, implFlags & Hooks.AFTER_DONATE_FLAG != 0);
        assertEq(permissions.beforeSwapReturnDelta, implFlags & Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG != 0);
        assertEq(permissions.afterSwapReturnDelta, implFlags & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0);
        assertEq(
            permissions.afterAddLiquidityReturnDelta, implFlags & Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG != 0
        );
        assertEq(
            permissions.afterRemoveLiquidityReturnDelta,
            implFlags & Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG != 0
        );
    }

    function test_fuzz_beforeInitialize_revertsIfNotStrategy(address notStrategy, uint160 sqrtPriceX96) public {
        vm.assume(notStrategy != strategy);
        MockHookProxyImpl impl = new MockHookProxyImpl(0, false, true);
        HookProxy proxy = _deployProxy(address(impl), Hooks.BEFORE_INITIALIZE_FLAG);
        PoolKey memory key = _defaultPoolKey(address(proxy));

        vm.expectRevert(abi.encodeWithSelector(HookProxy.InvalidInitializer.selector, notStrategy, strategy));
        proxy.beforeInitialize(notStrategy, key, sqrtPriceX96);
    }

    function test_fuzz_beforeInitialize_returnsSelectorIfImplDoesNotImplement(uint160 sqrtPriceX96) public {
        MockHookProxyImpl impl = new MockHookProxyImpl(0, false, true);
        HookProxy proxy = _deployProxy(address(impl), Hooks.BEFORE_INITIALIZE_FLAG);
        PoolKey memory key = _defaultPoolKey(address(proxy));

        bytes4 result = proxy.beforeInitialize(strategy, key, sqrtPriceX96);

        assertEq(result, IHooks.beforeInitialize.selector);
    }

    function test_fuzz_beforeInitialize_delegatesIfImplImplements(uint160 sqrtPriceX96) public {
        MockHookProxyImpl impl = new MockHookProxyImpl(Hooks.BEFORE_INITIALIZE_FLAG, false, false);
        HookProxy proxy = _deployProxy(address(impl), Hooks.BEFORE_INITIALIZE_FLAG);
        PoolKey memory key = _defaultPoolKey(address(proxy));

        vm.expectEmit(address(proxy));
        emit MockHookProxyImpl.BeforeInitializeForwarded(strategy, sqrtPriceX96);

        bytes4 result = proxy.beforeInitialize(strategy, key, sqrtPriceX96);

        assertEq(result, IHooks.beforeInitialize.selector);
    }

    function test_fuzz_forwardsAllSelectors(bytes4 selector, bytes32 payload, address caller, uint96 value) public {
        vm.assume(!_isProxySelector(selector));
        MockHookProxyImpl impl = new MockHookProxyImpl(0, false, false);
        HookProxy proxy = _deployProxy(address(impl), Hooks.BEFORE_INITIALIZE_FLAG);
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

    function _deployProxy(address impl, uint160 flags) internal returns (HookProxy proxy) {
        bytes memory args = abi.encode(impl, strategy);
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(HookProxy).creationCode, args);

        proxy = new HookProxy{salt: salt}(impl, strategy);

        assertEq(address(proxy), hookAddr);
        assertEq(uint160(address(proxy)) & HookMiner.FLAG_MASK, flags);
    }

    function _isProxySelector(bytes4 selector) internal pure returns (bool) {
        return selector == HookProxy.beforeInitialize.selector || selector == HookProxy.getHookPermissions.selector
            || selector == bytes4(keccak256("impl()")) || selector == bytes4(keccak256("strategy()"));
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
