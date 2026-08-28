// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {FeeSplitter} from "../../src/periphery/FeeSplitter.sol";
import {FeeSplit} from "../../src/interfaces/IFeeSplitter.sol";
import {IClaimExecutor} from "../../src/interfaces/IClaimExecutor.sol";
import {CompoundingClaimRecipient} from "../../src/periphery/CompoundingClaimRecipient.sol";
import {FullRangeGuardian} from "../../src/periphery/FullRangeGuardian.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice An honest searcher: takes the payout and compounds the required increase into the target.
contract HonestSearcher is IClaimExecutor {
    IPositionManager internal immutable positionManager;
    FeeSplitter internal immutable feeSplitter;
    WETH internal immutable weth;
    IERC20 internal immutable token;
    uint128 internal immutable increase;

    constructor(IPositionManager _pm, FeeSplitter _fs, WETH _weth, IERC20 _token, uint128 _increase) {
        positionManager = _pm;
        feeSplitter = _fs;
        weth = _weth;
        token = _token;
        increase = _increase;
    }

    function run(FullRangeGuardian guard, uint256 guardedTokenId) external {
        guard.claim(guardedTokenId, 0, 0);
    }

    function onClaimed(PoolKey memory, uint256 tokenId, uint256, uint256) external override {
        weth.deposit{value: address(this).balance}();
        weth.transfer(address(positionManager), weth.balanceOf(address(this)));
        token.transfer(address(positionManager), token.balanceOf(address(this)));
        feeSplitter.increaseLiquidity(tokenId, increase, type(uint128).max, type(uint128).max, bytes(""));
    }

    receive() external payable {}
}

/// @notice Tries to absorb the freed capacity into its OWN positions on both boundaries, symmetrically.
/// @dev This is the shape that defeats a boundary-total-only check: taking the same amount at each tick
///      leaves both exactly on the cap.
contract SymmetricSeizingSearcher is IClaimExecutor {
    IPositionManager internal immutable positionManager;
    IERC20 internal immutable token;
    PoolKey internal key;
    uint256 public lowerId;
    uint256 public upperId;
    uint128 internal immutable steal;

    constructor(IPositionManager _pm, IERC20 _token, PoolKey memory _key, uint128 _steal) {
        positionManager = _pm;
        token = _token;
        key = _key;
        steal = _steal;
    }

    function setPositions(uint256 _lowerId, uint256 _upperId) external {
        lowerId = _lowerId;
        upperId = _upperId;
    }

    function run(FullRangeGuardian guard, uint256 guardedTokenId) external {
        guard.claim(guardedTokenId, 0, 0);
    }

    function onClaimed(PoolKey memory, uint256, uint256, uint256) external override {
        _increase(lowerId);
        _increase(upperId);
    }

    function _increase(uint256 tokenId) private {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(tokenId, steal, type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency0, key.currency1, address(this));

        token.transfer(address(positionManager), token.balanceOf(address(this)));
        positionManager.modifyLiquidities{value: address(this).balance}(abi.encode(actions, params), block.timestamp);
    }

    receive() external payable {}
}

contract FullRangeGuardianTest is Test {
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager internal constant POSITION_MANAGER = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);

    uint24 internal constant LP_FEE = 2_500;
    int24 internal constant TICK_SPACING = 50;
    int24 internal constant LAUNCH_TICK = 190_600;
    uint128 internal constant MIN_LIQUIDITY_INCREASE = 1e20;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant LP_TOKEN_AMOUNT = 500_000_000 ether;
    uint256 internal constant LP_NATIVE_AMOUNT = 2_631_121_285_999_999_999;

    WETH internal weth;
    MockERC20 internal token;
    FeeSplitter internal feeSplitter;
    FullRangeGuardian internal guard;
    CompoundingClaimRecipient internal compounder;
    PoolKey internal key;

    uint256 internal guardedTokenId;
    uint256 internal lowerId;
    uint256 internal upperId;
    uint128 internal targetLiquidity;
    int24 internal lowerBoundary;
    int24 internal upperBoundary;

    address internal guardianOwner = makeAddr("guardian owner");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        weth = new WETH();
        deployCodeTo("lib/v4-core/src/PoolManager.sol:PoolManager", abi.encode(address(this)), address(POOL_MANAGER));
        deployCodeTo(
            "lib/v4-periphery/src/PositionManager.sol:PositionManager",
            abi.encode(POOL_MANAGER, address(0), uint256(0), address(0), address(weth)),
            address(POSITION_MANAGER)
        );

        token = new MockERC20("Crowd Launch", "CROWD", TOTAL_SUPPLY, address(this));
        compounder = new CompoundingClaimRecipient(POSITION_MANAGER, MIN_LIQUIDITY_INCREASE);
        FeeSplit[] memory splits = new FeeSplit[](1);
        splits[0] = FeeSplit({recipient: address(compounder), quoteBps: 10_000, tokenBps: 10_000, useCallback: true});
        feeSplitter = new FeeSplitter(POSITION_MANAGER, Currency.wrap(address(0)), splits);

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(LAUNCH_TICK));

        lowerBoundary = TickMath.minUsableTick(TICK_SPACING);
        upperBoundary = TickMath.maxUsableTick(TICK_SPACING);

        vm.deal(address(this), 1_000 ether);
        targetLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(LAUNCH_TICK),
            TickMath.getSqrtPriceAtTick(lowerBoundary),
            TickMath.getSqrtPriceAtTick(upperBoundary),
            LP_NATIVE_AMOUNT,
            LP_TOKEN_AMOUNT
        );
        guardedTokenId = _mint(lowerBoundary, upperBoundary, targetLiquidity, address(feeSplitter));
    }

    // --- control -------------------------------------------------------------------------------

    /// @notice With no companions, a few millionths of a token permanently freezes compounding.
    function test_control_unprotectedBoundaryIsCheapToFill() public {
        uint128 companionLiquidity = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING) - targetLiquidity;
        uint256 tokenBefore = token.balanceOf(address(this));
        _mint(lowerBoundary, lowerBoundary + TICK_SPACING, companionLiquidity, attacker);
        assertLt(tokenBefore - token.balanceOf(address(this)), 0.00001 ether, "boundary was not cheap to saturate");

        vm.expectRevert(abi.encodeWithSelector(Pool.TickLiquidityOverflow.selector, lowerBoundary));
        feeSplitter.increaseLiquidity(
            guardedTokenId, MIN_LIQUIDITY_INCREASE, type(uint128).max, type(uint128).max, bytes("")
        );
    }

    // --- deployment ----------------------------------------------------------------------------

    /// @notice Once the companions exist, both boundaries are at the cap and the attack has no room.
    function test_deployedGuardLeavesNoRoomAtEitherBoundary() public {
        _deployGuard();

        uint128 cap = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
        assertEq(_grossAt(lowerBoundary), cap, "lower boundary not saturated");
        assertEq(_grossAt(upperBoundary), cap, "upper boundary not saturated");

        // Inline so `expectRevert` attaches to `modifyLiquidities`, not the helper's first transfer.
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            key,
            lowerBoundary,
            lowerBoundary + TICK_SPACING,
            uint128(1e18),
            type(uint128).max,
            type(uint128).max,
            attacker,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency0, key.currency1, address(this));
        token.transfer(address(POSITION_MANAGER), 1_000_000 ether);

        vm.expectRevert(abi.encodeWithSelector(Pool.TickLiquidityOverflow.selector, lowerBoundary));
        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function test_register_revertsWhenACompanionAliasesTheGuarded() public {
        _mintCompanions();
        FullRangeGuardian.GuardedPosition[] memory g = new FullRangeGuardian.GuardedPosition[](1);
        g[0] = FullRangeGuardian.GuardedPosition({
            guardedTokenId: guardedTokenId,
            companions: FullRangeGuardian.Companions(uint128(guardedTokenId), uint128(upperId))
        });
        FullRangeGuardian g_ = _deployBare();
        vm.expectRevert(abi.encodeWithSelector(FullRangeGuardian.CompanionAliasesGuarded.selector, guardedTokenId));
        g_.register(g);
    }

    function test_register_revertsOnDuplicateTarget() public {
        _mintCompanions();
        FullRangeGuardian.GuardedPosition[] memory g = new FullRangeGuardian.GuardedPosition[](2);
        g[0] = FullRangeGuardian.GuardedPosition(
            guardedTokenId, FullRangeGuardian.Companions(uint128(lowerId), uint128(upperId))
        );
        g[1] = g[0];
        FullRangeGuardian g_ = _deployBare();
        IERC721(address(POSITION_MANAGER)).transferFrom(address(this), address(g_), lowerId);
        IERC721(address(POSITION_MANAGER)).transferFrom(address(this), address(g_), upperId);
        vm.expectRevert(abi.encodeWithSelector(FullRangeGuardian.DuplicateTarget.selector, guardedTokenId));
        g_.register(g);
    }

    function test_register_onlyDeployer() public {
        _mintCompanions();
        FullRangeGuardian g_ = _deployBare();
        FullRangeGuardian.GuardedPosition[] memory g = new FullRangeGuardian.GuardedPosition[](1);
        g[0] = FullRangeGuardian.GuardedPosition(
            guardedTokenId, FullRangeGuardian.Companions(uint128(lowerId), uint128(upperId))
        );
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(FullRangeGuardian.NotDeployer.selector, attacker));
        g_.register(g);
    }

    function test_register_revertsOnZeroTokenId() public {
        _mintCompanions();
        FullRangeGuardian g_ = _deployBare();
        FullRangeGuardian.GuardedPosition[] memory g = new FullRangeGuardian.GuardedPosition[](1);
        g[0] = FullRangeGuardian.GuardedPosition(guardedTokenId, FullRangeGuardian.Companions(0, uint128(upperId)));
        vm.expectRevert(abi.encodeWithSelector(FullRangeGuardian.ZeroTokenId.selector, guardedTokenId));
        g_.register(g);
    }

    function test_burnOwner_locksCompanionsForever() public {
        _deployGuard();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(FullRangeGuardian.NotOwner.selector, attacker));
        guard.burnOwner();

        vm.prank(guardianOwner);
        guard.burnOwner();
        assertEq(guard.owner(), address(0), "owner not burned");

        // Nobody can pull a companion out any more, so the boundaries stay held for good.
        vm.prank(guardianOwner);
        vm.expectRevert(abi.encodeWithSelector(FullRangeGuardian.NotOwner.selector, guardianOwner));
        guard.transferPosition(lowerId);
    }

    function test_amounts_forwardsToTheCompounder() public {
        _deployGuard();
        (uint128 a0, uint128 a1) = guard.amounts(guardedTokenId);
        (uint128 c0, uint128 c1) = compounder.amounts(guardedTokenId);
        assertEq(a0, c0, "currency0 mismatch");
        assertEq(a1, c1, "currency1 mismatch");
    }

    /// @notice zerocool M-04: companion ids in a register call can become stale if nextTokenId moves
    ///         before the call lands. A shifted id belongs to someone else.
    function test_register_revertsWhenACompanionIsNotHeldHere() public {
        _mintCompanions();
        FullRangeGuardian g_ = _deployBare();
        // Only the lower companion made it in; the upper id in the entry is still ours, as a shifted id
        // would be someone else's.
        IERC721(address(POSITION_MANAGER)).transferFrom(address(this), address(g_), lowerId);

        FullRangeGuardian.GuardedPosition[] memory g = new FullRangeGuardian.GuardedPosition[](1);
        g[0] = FullRangeGuardian.GuardedPosition(
            guardedTokenId, FullRangeGuardian.Companions(uint128(lowerId), uint128(upperId))
        );
        vm.expectRevert(
            abi.encodeWithSelector(FullRangeGuardian.CompanionNotOwned.selector, guardedTokenId, upperId, address(this))
        );
        g_.register(g);
    }

    // --- claim ---------------------------------------------------------------------------------

    /// @notice An honest searcher compounds through the guard and both boundaries close at the cap.
    function test_claim_compoundsAndReclosesBothBoundaries() public {
        _deployGuard();

        HonestSearcher searcher =
            new HonestSearcher(POSITION_MANAGER, feeSplitter, weth, IERC20(address(token)), MIN_LIQUIDITY_INCREASE);
        token.transfer(address(searcher), 20_000_000 ether);
        vm.deal(address(searcher), 10 ether);

        uint128 before = POSITION_MANAGER.getPositionLiquidity(guardedTokenId);
        searcher.run(guard, guardedTokenId);

        assertEq(
            POSITION_MANAGER.getPositionLiquidity(guardedTokenId),
            before + MIN_LIQUIDITY_INCREASE,
            "target did not absorb the freed capacity"
        );
        uint128 cap = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
        assertEq(_grossAt(lowerBoundary), cap, "lower boundary left open");
        assertEq(_grossAt(upperBoundary), cap, "upper boundary left open");
    }

    /// @notice Regression: absorbing the freed capacity into the caller's OWN boundary positions, at BOTH
    ///         ticks symmetrically, leaves each tick exactly on the cap. A boundary-total-only check passes
    ///         it; requiring the target to absorb the capacity does not.
    function test_claim_revertsWhenTheSearcherSeizesBothBoundaries() public {
        SymmetricSeizingSearcher thief =
            new SymmetricSeizingSearcher(POSITION_MANAGER, IERC20(address(token)), key, MIN_LIQUIDITY_INCREASE);
        // Dust positions on each boundary, planted before the companions are sized around them.
        uint256 thiefLower = _mint(lowerBoundary, lowerBoundary + TICK_SPACING, 1e18, address(thief));
        uint256 thiefUpper = _mint(upperBoundary - TICK_SPACING, upperBoundary, 1e18, address(thief));
        thief.setPositions(thiefLower, thiefUpper);

        _deployGuard();

        token.transfer(address(thief), 10_000_000 ether);
        vm.deal(address(thief), 100 ether);

        uint128 guardLowerBefore = POSITION_MANAGER.getPositionLiquidity(uint128(lowerId));
        vm.expectRevert();
        thief.run(guard, guardedTokenId);

        // Nothing moved.
        assertEq(POSITION_MANAGER.getPositionLiquidity(uint128(lowerId)), guardLowerBefore);
        assertEq(POSITION_MANAGER.getPositionLiquidity(uint128(thiefLower)), 1e18);
        assertEq(POSITION_MANAGER.getPositionLiquidity(uint128(thiefUpper)), 1e18);
    }

    // --- rescue --------------------------------------------------------------------------------

    function test_transferPosition_onlyOwner() public {
        _deployGuard();

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(FullRangeGuardian.NotOwner.selector, attacker));
        guard.transferPosition(lowerId);

        vm.prank(guardianOwner);
        guard.transferPosition(lowerId);
        assertEq(IERC721(address(POSITION_MANAGER)).ownerOf(lowerId), guardianOwner);
    }

    // --- helpers -------------------------------------------------------------------------------

    function _mintCompanions() private {
        uint128 cap = Pool.tickSpacingToMaxLiquidityPerTick(TICK_SPACING);
        if (lowerId == 0) {
            lowerId = _mint(lowerBoundary, lowerBoundary + TICK_SPACING, cap - _grossAt(lowerBoundary), address(this));
            upperId = _mint(upperBoundary - TICK_SPACING, upperBoundary, cap - _grossAt(upperBoundary), address(this));
        }
    }

    function _deployWith(FullRangeGuardian.GuardedPosition[] memory g) private returns (FullRangeGuardian) {
        address[] memory splitters = new address[](1);
        splitters[0] = address(feeSplitter);
        address[] memory compounders = new address[](1);
        compounders[0] = address(compounder);
        FullRangeGuardian g_ = _deployBare();
        g_.register(g);
        return g_;
    }

    function _deployBare() private returns (FullRangeGuardian) {
        address[] memory splitters = new address[](1);
        splitters[0] = address(feeSplitter);
        address[] memory compounders = new address[](1);
        compounders[0] = address(compounder);
        return new FullRangeGuardian(POSITION_MANAGER, guardianOwner, splitters, compounders);
    }

    function _deployGuard() private {
        _mintCompanions();
        FullRangeGuardian.GuardedPosition[] memory g = new FullRangeGuardian.GuardedPosition[](1);
        g[0] = FullRangeGuardian.GuardedPosition(
            guardedTokenId, FullRangeGuardian.Companions(uint128(lowerId), uint128(upperId))
        );
        // Companions must be held by the guardian before register.
        guard = _deployBare();
        IERC721(address(POSITION_MANAGER)).transferFrom(address(this), address(guard), lowerId);
        IERC721(address(POSITION_MANAGER)).transferFrom(address(this), address(guard), upperId);
        guard.register(g);
    }

    function _grossAt(int24 tick) private view returns (uint128 g) {
        bytes32 poolId = keccak256(abi.encode(key));
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        bytes32 slot = keccak256(abi.encodePacked(int256(tick), bytes32(uint256(stateSlot) + 4)));
        bytes32 v = POOL_MANAGER.extsload(slot);
        assembly {
            g := and(v, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    function _mint(int24 tickLower, int24 tickUpper, uint128 liquidity, address owner)
        private
        returns (uint256 tokenId)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] =
            abi.encode(key, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, owner, bytes(""));
        params[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency0, key.currency1, address(this));

        tokenId = POSITION_MANAGER.nextTokenId();
        token.transfer(address(POSITION_MANAGER), token.balanceOf(address(this)) / 2);
        POSITION_MANAGER.modifyLiquidities{value: address(this).balance / 2}(
            abi.encode(actions, params), block.timestamp
        );
    }

    receive() external payable {}
}
