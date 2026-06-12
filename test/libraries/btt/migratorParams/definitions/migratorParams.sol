// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MigratorParams} from "src/libraries/MigratorParams.sol";
import {IInitializerHook} from "src/interfaces/IInitializerHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @notice Exposes the internal MigratorParams.validateHook so the chained validation logic can be
/// unit-tested directly. Because internal library functions are inlined into the caller, `address(this)`
/// inside validateHook resolves to this harness — so a hook authorized to the harness passes the
/// authorization clause.
contract MigratorParamsHarness {
    function validateHook(address hook, uint24 fee, PoolId poolId, IPoolManager poolManager) external view {
        MigratorParams.validateHook(hook, fee, poolId, poolManager);
    }
}

/// @notice Minimal pool manager stub. StateLibrary.getSlot0 reads the pool's slot0 via extsload and
/// interprets the bottom 160 bits as sqrtPriceX96; returning a configurable value lets a test toggle
/// the "pool already initialized" branch without standing up a real PoolManager.
contract MockSlot0PoolManager {
    bytes32 internal _slot0;

    function setSqrtPriceX96(uint160 sqrtPriceX96) external {
        _slot0 = bytes32(uint256(sqrtPriceX96));
    }

    function extsload(bytes32) external view returns (bytes32) {
        return _slot0;
    }
}

/// @notice A hook that implements IInitializerHook and reports a configurable authorized address.
contract MockInitializerHook {
    address public immutable authorized;

    constructor(address _authorized) {
        authorized = _authorized;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IInitializerHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice A contract that is not an IInitializerHook (ERC165 reports support for nothing).
contract MockUnsupportedHook {
    function supportsInterface(bytes4) external pure returns (bool) {
        return false;
    }
}

/// @title MigratorParamsTest
/// @notice BTT unit tests for the MigratorParams library, focused on the chained validation logic in
/// validateHook. The four `||` clauses are reached left-to-right with short-circuiting, so each test
/// arranges exactly one clause to be the first failing one, and the zero-address `&&` guard plus the
/// trailing pool-initialization check are covered independently.
///
/// validateHook
/// ├── when the hook is the zero address
/// │   ├── when the pool is already initialized
/// │   │   └── it reverts with {InvalidHook}
/// │   └── when the pool is not initialized
/// │       └── it does not revert
/// └── when the hook is not the zero address
///     ├── when the hook does not support the IInitializerHook interface
///     │   └── it reverts with {InvalidHook}
///     ├── when the hook is not authorized to the caller
///     │   └── it reverts with {InvalidHook}
///     ├── when the hook is not a valid v4 hook address for the fee
///     │   └── it reverts with {InvalidHook}
///     ├── when the hook lacks the before-initialize permission bit
///     │   └── it reverts with {InvalidHook}
///     └── when the hook passes every hook check
///         ├── when the pool is already initialized
///         │   └── it reverts with {InvalidHook}
///         └── when the pool is not initialized
///             └── it does not revert
contract MigratorParamsTest is Test {
    /// @notice A normal static fee; isValidHookAddress only consults the fee for dynamic-fee pools, which
    /// these tests never exercise, so any non-dynamic value works.
    uint24 internal constant FEE = 3000;

    MigratorParamsHarness internal harness;
    MockSlot0PoolManager internal poolManager;

    /// @notice The mock pool manager ignores the slot key, so the poolId value is irrelevant — it only
    /// exists to satisfy the signature while the configured slot0 drives the initialization branch.
    PoolId internal poolId = PoolId.wrap(bytes32(uint256(1)));

    function setUp() public {
        harness = new MigratorParamsHarness();
        poolManager = new MockSlot0PoolManager();
    }

    /// @notice Deploys a MockInitializerHook and etches it at `addressBits`, so the hook satisfies v4's
    /// address-derived permission rules. The `authorized` immutable is baked into runtime code and
    /// survives the etch.
    function _etchInitializerHook(uint160 addressBits, address _authorized) internal returns (address hookAddr) {
        hookAddr = address(addressBits);
        MockInitializerHook impl = new MockInitializerHook(_authorized);
        vm.etch(hookAddr, address(impl).code);
    }

    modifier whenTheHookIsTheZeroAddress() {
        _;
    }

    function test_ValidateHook_WhenTheHookIsTheZeroAddress_WhenThePoolIsAlreadyInitialized(uint160 _sqrtPriceX96)
        public
        whenTheHookIsTheZeroAddress
    {
        // it reverts with {InvalidHook}
        // A zero hook skips the inner clauses (the leading `&&`), but the pool-initialization guard still applies.
        _sqrtPriceX96 = uint160(bound(_sqrtPriceX96, 1, type(uint160).max));
        poolManager.setSqrtPriceX96(_sqrtPriceX96);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, address(0)));
        harness.validateHook(address(0), FEE, poolId, IPoolManager(address(poolManager)));
    }

    function test_ValidateHook_WhenTheHookIsTheZeroAddress_WhenThePoolIsNotInitialized()
        public
        whenTheHookIsTheZeroAddress
    {
        // it does not revert
        poolManager.setSqrtPriceX96(0);

        harness.validateHook(address(0), FEE, poolId, IPoolManager(address(poolManager)));
    }

    modifier whenTheHookIsNotTheZeroAddress() {
        _;
    }

    function test_ValidateHook_WhenTheHookDoesNotSupportTheIInitializerHookInterface()
        public
        whenTheHookIsNotTheZeroAddress
    {
        // it reverts with {InvalidHook}
        // First OR clause: a non-IInitializerHook contract fails the ERC165 check before authorization or
        // address-bit checks are reached. A clear (uninitialized) pool isolates the hook check as the cause.
        address hook = address(new MockUnsupportedHook());
        poolManager.setSqrtPriceX96(0);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, hook));
        harness.validateHook(hook, FEE, poolId, IPoolManager(address(poolManager)));
    }

    function test_ValidateHook_WhenTheHookIsNotAuthorizedToTheCaller(address _authorized)
        public
        whenTheHookIsNotTheZeroAddress
    {
        // it reverts with {InvalidHook}
        // Second OR clause: the hook implements IInitializerHook but is authorized to someone other than the
        // caller (the inlined `address(this)` is the harness).
        vm.assume(_authorized != address(harness));
        address hook = address(new MockInitializerHook(_authorized));
        poolManager.setSqrtPriceX96(0);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, hook));
        harness.validateHook(hook, FEE, poolId, IPoolManager(address(poolManager)));
    }

    function test_ValidateHook_WhenTheHookIsNotAValidV4HookAddressForTheFee() public whenTheHookIsNotTheZeroAddress {
        // it reverts with {InvalidHook}
        // Third OR clause: the hook supports the interface and is authorized to the caller, but its address sets
        // the before-swap-return-delta flag without the before-swap flag, so isValidHookAddress returns false.
        uint160 hookBits = Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | (uint160(1) << 60);
        address hook = _etchInitializerHook(hookBits, address(harness));
        poolManager.setSqrtPriceX96(0);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, hook));
        harness.validateHook(hook, FEE, poolId, IPoolManager(address(poolManager)));
    }

    function test_ValidateHook_WhenTheHookLacksTheBeforeInitializePermissionBit()
        public
        whenTheHookIsNotTheZeroAddress
    {
        // it reverts with {InvalidHook}
        // Fourth OR clause: a valid hook address (after-initialize flag set, so isValidHookAddress passes) that
        // lacks the before-initialize bit. Without it v4 never calls beforeInitialize and the strategy's
        // initialization gate would be silently skipped.
        address hook = _etchInitializerHook(uint160(Hooks.AFTER_INITIALIZE_FLAG), address(harness));
        poolManager.setSqrtPriceX96(0);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, hook));
        harness.validateHook(hook, FEE, poolId, IPoolManager(address(poolManager)));
    }

    modifier whenTheHookPassesEveryHookCheck() {
        _;
    }

    function test_ValidateHook_WhenTheHookPassesEveryHookCheck_WhenThePoolIsAlreadyInitialized(uint160 _sqrtPriceX96)
        public
        whenTheHookIsNotTheZeroAddress
        whenTheHookPassesEveryHookCheck
    {
        // it reverts with {InvalidHook}
        _sqrtPriceX96 = uint160(bound(_sqrtPriceX96, 1, type(uint160).max));
        address hook = _etchInitializerHook(uint160(Hooks.BEFORE_INITIALIZE_FLAG), address(harness));
        poolManager.setSqrtPriceX96(_sqrtPriceX96);

        vm.expectRevert(abi.encodeWithSelector(MigratorParams.InvalidHook.selector, hook));
        harness.validateHook(hook, FEE, poolId, IPoolManager(address(poolManager)));
    }

    function test_ValidateHook_WhenTheHookPassesEveryHookCheck_WhenThePoolIsNotInitialized()
        public
        whenTheHookIsNotTheZeroAddress
        whenTheHookPassesEveryHookCheck
    {
        // it does not revert
        address hook = _etchInitializerHook(uint160(Hooks.BEFORE_INITIALIZE_FLAG), address(harness));
        poolManager.setSqrtPriceX96(0);

        harness.validateHook(hook, FEE, poolId, IPoolManager(address(poolManager)));
    }
}
