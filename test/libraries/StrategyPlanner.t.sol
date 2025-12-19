// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import {Test} from "forge-std/Test.sol";
// import {StrategyPlanner} from "src/libraries/StrategyPlanner.sol";
// import {BasePositionParams} from "src/types/PositionTypes.sol";
// import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// import {ActionsBuilder} from "src/libraries/ActionsBuilder.sol";
// import {ParamsBuilder} from "src/libraries/ParamsBuilder.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
// import {TickBounds} from "src/types/PositionTypes.sol";
// import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
// import {TickCalculations} from "src/libraries/TickCalculations.sol";
// import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
// import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
// import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
// import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
// import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

// contract StrategyPlannerHelper is Test {
//     function planFullRangePosition(
//         BasePositionParams memory baseParams,
//         uint128 tokenAmount,
//         uint128 currencyAmount
//     ) public pure returns (bytes memory param) {
//         return StrategyPlanner.planFullRangePosition(baseParams, tokenAmount, currencyAmount);
//     }

//     function planOneSidedPosition(
//         BasePositionParams memory baseParams,
//         uint128 tokenAmount,
//         uint128 currencyAmount,
//     ) public pure returns (bytes memory param) {
//         return StrategyPlanner.planOneSidedPosition(baseParams, tokenAmount, currencyAmount);
//     }
// }

// contract StrategyPlannerTest is Test {
//     using TickCalculations for int24;
//     using SafeCast for uint256;

//     StrategyPlannerHelper testHelper;

//     function setUp() public {
//         testHelper = new StrategyPlannerHelper();
//     }

//     function test_planFullRangePosition_succeeds() public view {
//         bytes memory param = testHelper.planFullRangePosition(
//             BasePositionParams({
//                 currency: address(0),
//                 poolToken: address(1),
//                 poolLPFee: 10000,
//                 poolTickSpacing: 1,
//                 initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
//                 liquidity: 1000000000000000000,
//                 positionRecipient: address(0),
//                 hooks: IHooks(address(0))
//             }),
//             1000000000000000000,
//             1000000000000000000
//         );
//         assertEq(param.length, 1);
//         assertEq(
//             param,
//             ParamsBuilder.addMintParam(
//                 PoolKey({
//                     currency0: Currency.wrap(address(0)),
//                     currency1: Currency.wrap(address(1)),
//                     fee: 10000,
//                     tickSpacing: 1,
//                     hooks: IHooks(address(0))
//                 }),
//                 TickBounds({ lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK }),
//                 LiquidityAmounts.getLiquidityForAmounts(
//                     TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
//                     TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK), 1000000000000000000, 1000000000000000000
//                 ),
//                 1000000000000000000,
//                 1000000000000000000,
//                 address(0),
//                 ParamsBuilder.ZERO_BYTES
//             )
//         );

//         assertEq(params[1], abi.encode(Currency.wrap(address(0)), ActionConstants.CONTRACT_BALANCE, false));
//         assertEq(params[2], abi.encode(Currency.wrap(address(1)), ActionConstants.CONTRACT_BALANCE, false));
//     }

//     function test_fuzz_planFullRangePosition_succeeds(
//         BasePositionParams memory baseParams,
//         FullRangeParams memory fullRangeParams
//     ) public view {
//         baseParams.poolTickSpacing = int24(
//             bound(baseParams.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING)
//         );
//         baseParams.poolLPFee = uint24(bound(baseParams.poolLPFee, 0, LPFeeLibrary.MAX_LP_FEE));
//         baseParams.liquidity = uint128(bound(baseParams.liquidity, 0, type(uint128).max));
//         baseParams.initialSqrtPriceX96 =
//             uint160(bound(baseParams.initialSqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
//         fullRangeParams.tokenAmount = uint128(bound(fullRangeParams.tokenAmount, 0, type(uint128).max));
//         fullRangeParams.currencyAmount = uint128(bound(fullRangeParams.currencyAmount, 0, type(uint128).max));

//         bytes memory param = testHelper.planFullRangePosition(baseParams, fullRangeParams);
//         assertEq(param.length, 1);
//         assertEq(param, ActionsBuilder.addMint());

//         assertEq(
//             param,
//             ParamsBuilder.addMintParam(
//                 PoolKey({
//                     currency0: Currency.wrap(
//                         baseParams.currency < baseParams.poolToken ? baseParams.currency : baseParams.poolToken
//                     ),
//                     currency1: Currency.wrap(
//                         baseParams.currency < baseParams.poolToken ? baseParams.poolToken : baseParams.currency
//                     ),
//                     fee: baseParams.poolLPFee,
//                     tickSpacing: baseParams.poolTickSpacing,
//                     hooks: baseParams.hooks
//                 }),
//                 TickBounds({ lowerTick: TickMath.MIN_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing, upperTick: TickMath.MAX_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing }),
//                 TickMath.MAX_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing,
//                 baseParams.liquidity,
//                 baseParams.currency < baseParams.poolToken
//                     ? fullRangeParams.currencyAmount
//                     : fullRangeParams.tokenAmount,
//                 baseParams.currency < baseParams.poolToken
//                     ? fullRangeParams.tokenAmount
//                     : fullRangeParams.currencyAmount,
//                 baseParams.positionRecipient,
//                 ParamsBuilder.ZERO_BYTES
//             )
//         );

//         assertEq(
//             params[1],
//             abi.encode(
//                 Currency.wrap(baseParams.currency < baseParams.poolToken ? baseParams.currency : baseParams.poolToken),
//                 ActionConstants.CONTRACT_BALANCE,
//                 false
//             )
//         );
//         assertEq(
//             params[2],
//             abi.encode(
//                 Currency.wrap(baseParams.currency < baseParams.poolToken ? baseParams.poolToken : baseParams.currency),
//                 ActionConstants.CONTRACT_BALANCE,
//                 false
//             )
//         );
//     }

//     function test_planOneSidedPosition_inToken_succeeds() public view {
//         uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
//             TickMath.getSqrtPriceAtTick(0),
//             TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
//             TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
//             1000000000000000000,
//             1000000000000000000
//         );
//         bytes memory existingActions = ActionsBuilder.addMint();
//         bytes[] memory existingParams = ParamsBuilder.buildFullRangeParams(
//             FullRangeParams({tokenAmount: 1000000000000000000, currencyAmount: 1000000000000000000}),
//             PoolKey({
//                 currency0: Currency.wrap(address(0)),
//                 currency1: Currency.wrap(address(1)),
//                 fee: 10000,
//                 tickSpacing: 1,
//                 hooks: IHooks(address(0))
//             }),
//             TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
//             true,
//             5,
//             address(0),
//             liquidity
//         );
//         (bytes memory actions, bytes[] memory params) = testHelper.planOneSidedPosition(
//             BasePositionParams({
//                 currency: address(0),
//                 poolToken: address(1),
//                 poolLPFee: 10000,
//                 poolTickSpacing: 1,
//                 initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
//                 liquidity: liquidity,
//                 positionRecipient: address(0),
//                 hooks: IHooks(address(0))
//             }),
//             OneSidedParams({amount: 1000000000000000000, inToken: true}),
//             existingActions,
//             existingParams
//         );
//         assertEq(actions.length, 4);
//         assertEq(params.length, 5);
//         assertEq(actions, ActionsBuilder.buildOneSidedActions(existingActions));

//         uint128 oneSidedLiquidity = LiquidityAmounts.getLiquidityForAmounts(
//             TickMath.getSqrtPriceAtTick(0),
//             TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
//             TickMath.getSqrtPriceAtTick(0),
//             0,
//             1000000000000000000
//         );

//         assertEq(
//             params[0],
//             abi.encode(
//                 PoolKey({
//                     currency0: Currency.wrap(address(0)),
//                     currency1: Currency.wrap(address(1)),
//                     fee: 10000,
//                     tickSpacing: 1,
//                     hooks: IHooks(address(0))
//                 }),
//                 TickMath.MIN_TICK,
//                 TickMath.MAX_TICK,
//                 liquidity,
//                 1000000000000000000,
//                 1000000000000000000,
//                 address(0),
//                 ParamsBuilder.ZERO_BYTES
//             )
//         );

//         assertEq(params[1], abi.encode(Currency.wrap(address(0)), ActionConstants.CONTRACT_BALANCE, false));
//         assertEq(params[2], abi.encode(Currency.wrap(address(1)), ActionConstants.CONTRACT_BALANCE, false));

//         assertEq(
//             params[3],
//             abi.encode(
//                 PoolKey({
//                     currency0: Currency.wrap(address(0)),
//                     currency1: Currency.wrap(address(1)),
//                     fee: 10000,
//                     tickSpacing: 1,
//                     hooks: IHooks(address(0))
//                 }),
//                 TickMath.MIN_TICK,
//                 0,
//                 oneSidedLiquidity,
//                 0,
//                 1000000000000000000,
//                 address(0),
//                 ParamsBuilder.ZERO_BYTES
//             )
//         );
//     }

//     function test_planOneSidedPosition_inCurrency_succeeds() public view {
//         uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
//             TickMath.getSqrtPriceAtTick(0),
//             TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
//             TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
//             1000000000000000000,
//             1000000000000000000
//         );
//         bytes memory existingActions = ActionsBuilder.addMint();
//         bytes[] memory existingParams = ParamsBuilder.buildFullRangeParams(
//             FullRangeParams({tokenAmount: 1000000000000000000, currencyAmount: 1000000000000000000}),
//             PoolKey({
//                 currency0: Currency.wrap(address(0)),
//                 currency1: Currency.wrap(address(1)),
//                 fee: 10000,
//                 tickSpacing: 1,
//                 hooks: IHooks(address(0))
//             }),
//             TickBounds({lowerTick: TickMath.MIN_TICK, upperTick: TickMath.MAX_TICK}),
//             true,
//             ParamsBuilder.FULL_RANGE_WITH_ONE_SIDED_SIZE,
//             address(0),
//             liquidity
//         );
//         (bytes memory actions, bytes[] memory params) = testHelper.planOneSidedPosition(
//             BasePositionParams({
//                 currency: address(0),
//                 poolToken: address(1),
//                 poolLPFee: 10000,
//                 poolTickSpacing: 1,
//                 initialSqrtPriceX96: TickMath.getSqrtPriceAtTick(0),
//                 liquidity: liquidity,
//                 positionRecipient: address(0),
//                 hooks: IHooks(address(0))
//             }),
//             OneSidedParams({amount: 1000000000000000000, inToken: false}),
//             existingActions,
//             existingParams
//         );
//         assertEq(actions.length, 4);
//         assertEq(params.length, 5);
//         assertEq(actions, ActionsBuilder.buildOneSidedActions(existingActions));
//         assertEq(
//             params[0],
//             abi.encode(
//                 PoolKey({
//                     currency0: Currency.wrap(address(0)),
//                     currency1: Currency.wrap(address(1)),
//                     fee: 10000,
//                     tickSpacing: 1,
//                     hooks: IHooks(address(0))
//                 }),
//                 TickMath.MIN_TICK,
//                 TickMath.MAX_TICK,
//                 liquidity,
//                 1000000000000000000,
//                 1000000000000000000,
//                 address(0),
//                 ParamsBuilder.ZERO_BYTES
//             )
//         );
//         assertEq(params[1], abi.encode(Currency.wrap(address(0)), ActionConstants.CONTRACT_BALANCE, false));
//         assertEq(params[2], abi.encode(Currency.wrap(address(1)), ActionConstants.CONTRACT_BALANCE, false));

//         assertEq(
//             params[3],
//             abi.encode(
//                 PoolKey({
//                     currency0: Currency.wrap(address(0)),
//                     currency1: Currency.wrap(address(1)),
//                     fee: 10000,
//                     tickSpacing: 1,
//                     hooks: IHooks(address(0))
//                 }),
//                 1,
//                 TickMath.MAX_TICK,
//                 LiquidityAmounts.getLiquidityForAmounts(
//                     TickMath.getSqrtPriceAtTick(0),
//                     TickMath.getSqrtPriceAtTick(1),
//                     TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
//                     1000000000000000000,
//                     0
//                 ),
//                 1000000000000000000,
//                 0,
//                 address(0),
//                 ParamsBuilder.ZERO_BYTES
//             )
//         );
//     }

//     function calculateLiquidity(
//         uint128 oldLiquidity,
//         uint160 sqrtPriceX96,
//         uint160 sqrtPriceAX96,
//         uint160 sqrtPriceBX96,
//         uint256 amount0,
//         uint256 amount1
//     ) external pure returns (uint128 liquidity) {
//         if (sqrtPriceAX96 > sqrtPriceBX96) {
//             (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
//         }

//         if (sqrtPriceX96 <= sqrtPriceAX96) {
//             liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
//         } else if (sqrtPriceX96 < sqrtPriceBX96) {
//             uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
//             uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);

//             liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
//         } else {
//             liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
//         }

//         return (oldLiquidity + liquidity);
//     }

//     function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
//         internal
//         pure
//         returns (uint128)
//     {
//         unchecked {
//             if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
//             uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
//             uint128 liquidity = FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96).toUint128();
//             return liquidity;
//         }
//     }

//     function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
//         internal
//         pure
//         returns (uint128)
//     {
//         unchecked {
//             if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
//             uint128 liquidity = FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtPriceBX96 - sqrtPriceAX96).toUint128();
//             return liquidity;
//         }
//     }

//     struct OneSidedTestData {
//         bytes fullActions;
//         bytes[] fullParams;
//         bytes actions;
//         bytes[] params;
//         TickBounds bounds;
//     }

//     function test_fuzz_planOneSidedPosition_succeeds(
//         BasePositionParams memory baseParams,
//         OneSidedParams memory oneSidedParams,
//         FullRangeParams memory fullRangeParams
//     ) public {
//         // Bound parameters
//         _boundBaseParams(baseParams);
//         _boundFullRangeParams(fullRangeParams);
//         _boundOneSidedParams(oneSidedParams, fullRangeParams);

//         OneSidedTestData memory testData;

//         // Plan full range position
//         (testData.fullActions, testData.fullParams) = testHelper.planFullRangePosition(baseParams, fullRangeParams, 5);

//         // Get tick bounds
//         testData.bounds = _getTickBounds(baseParams, oneSidedParams);
//         if (testData.bounds.lowerTick == 0 && testData.bounds.upperTick == 0) {
//             return;
//         }

//         // Check if should revert
//         if (_shouldRevertOnLiquidity(baseParams, oneSidedParams, testData.bounds)) {
//             vm.expectRevert();
//             testHelper.planOneSidedPosition(baseParams, oneSidedParams, testData.fullActions, testData.fullParams);
//             return;
//         }

//         // Plan one-sided position
//         (testData.actions, testData.params) =
//             testHelper.planOneSidedPosition(baseParams, oneSidedParams, testData.fullActions, testData.fullParams);

//         // Assert results
//         if (testData.actions.length == 3) {
//             assertEq(testData.actions, testData.fullActions);
//             assertEq(testData.params, ParamsBuilder.truncateParams(testData.fullParams));
//         } else {
//             _assertOneSidedPositionParams(baseParams, oneSidedParams, testData);
//         }
//     }

//     // Helper function to bound base parameters
//     function _boundBaseParams(BasePositionParams memory baseParams) private pure {
//         baseParams.poolTickSpacing =
//             int24(bound(baseParams.poolTickSpacing, TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
//         baseParams.poolLPFee = uint24(bound(baseParams.poolLPFee, 0, LPFeeLibrary.MAX_LP_FEE));
//         baseParams.liquidity = uint128(bound(baseParams.liquidity, 0, type(uint128).max));
//         baseParams.initialSqrtPriceX96 =
//             uint160(bound(baseParams.initialSqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
//     }

//     // Helper function to bound full range parameters
//     function _boundFullRangeParams(FullRangeParams memory fullRangeParams) private pure {
//         fullRangeParams.tokenAmount = uint128(bound(fullRangeParams.tokenAmount, 0, type(uint128).max - 1));
//         fullRangeParams.currencyAmount = uint128(bound(fullRangeParams.currencyAmount, 0, type(uint128).max - 1));
//     }

//     // Helper function to bound one-sided parameters
//     function _boundOneSidedParams(OneSidedParams memory oneSidedParams, FullRangeParams memory fullRangeParams)
//         private
//         pure
//     {
//         oneSidedParams.amount = oneSidedParams.inToken
//             ? uint128(bound(oneSidedParams.amount, 1, type(uint128).max - fullRangeParams.tokenAmount))
//             : uint128(bound(oneSidedParams.amount, 1, type(uint128).max - fullRangeParams.currencyAmount));
//     }

//     // Helper function to get tick bounds
//     function _getTickBounds(BasePositionParams memory baseParams, OneSidedParams memory oneSidedParams)
//         private
//         pure
//         returns (TickBounds memory)
//     {
//         return baseParams.currency < baseParams.poolToken == oneSidedParams.inToken
//             ? getLeftSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing)
//             : getRightSideBounds(baseParams.initialSqrtPriceX96, baseParams.poolTickSpacing);
//     }

//     // Helper function to check if liquidity calculation should revert
//     function _shouldRevertOnLiquidity(
//         BasePositionParams memory baseParams,
//         OneSidedParams memory oneSidedParams,
//         TickBounds memory bounds
//     ) private view returns (bool) {
//         try this.calculateLiquidity(
//             baseParams.liquidity,
//             baseParams.initialSqrtPriceX96,
//             TickMath.getSqrtPriceAtTick(bounds.lowerTick),
//             TickMath.getSqrtPriceAtTick(bounds.upperTick),
//             oneSidedParams.inToken == baseParams.currency < baseParams.poolToken ? 0 : oneSidedParams.amount,
//             oneSidedParams.inToken == baseParams.currency < baseParams.poolToken ? oneSidedParams.amount : 0
//         ) returns (
//             uint128
//         ) {
//             return false;
//         } catch {
//             return true;
//         }
//     }

//     // Helper function to assert one-sided position parameters
//     function _assertOneSidedPositionParams(
//         BasePositionParams memory baseParams,
//         OneSidedParams memory oneSidedParams,
//         OneSidedTestData memory testData
//     ) private pure {
//         assertEq(testData.actions.length, 4);
//         assertEq(testData.params.length, 5);
//         assertEq(testData.actions, ActionsBuilder.buildOneSidedActions(testData.fullActions));

//         // Assert params[3] - extract to separate function to reduce complexity
//         assertEq(testData.params[3], _buildParam3(baseParams, oneSidedParams));
//     }

//     // Helper function to build parameter 6
//     function _buildParam3(BasePositionParams memory baseParams, OneSidedParams memory oneSidedParams)
//         private
//         pure
//         returns (bytes memory)
//     {
//         bool isLeftSide = baseParams.currency < baseParams.poolToken == oneSidedParams.inToken;

//         // Use local variables in a scope to reduce stack usage
//         int24 lowerTick;
//         int24 upperTick;

//         {
//             if (isLeftSide) {
//                 lowerTick = TickMath.MIN_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing;
//                 upperTick =
//                     TickMath.getTickAtSqrtPrice(baseParams.initialSqrtPriceX96).tickFloor(baseParams.poolTickSpacing);
//             } else {
//                 lowerTick = TickMath.getTickAtSqrtPrice(baseParams.initialSqrtPriceX96)
//                     .tickStrictCeil(baseParams.poolTickSpacing);
//                 upperTick = TickMath.MAX_TICK / baseParams.poolTickSpacing * baseParams.poolTickSpacing;
//             }
//         }

//         uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
//             baseParams.initialSqrtPriceX96,
//             TickMath.getSqrtPriceAtTick(lowerTick),
//             TickMath.getSqrtPriceAtTick(upperTick),
//             isLeftSide ? 0 : oneSidedParams.amount,
//             isLeftSide ? oneSidedParams.amount : 0
//         );

//         return abi.encode(
//             PoolKey({
//                 currency0: Currency.wrap(
//                     baseParams.currency < baseParams.poolToken ? baseParams.currency : baseParams.poolToken
//                 ),
//                 currency1: Currency.wrap(
//                     baseParams.currency < baseParams.poolToken ? baseParams.poolToken : baseParams.currency
//                 ),
//                 fee: baseParams.poolLPFee,
//                 tickSpacing: baseParams.poolTickSpacing,
//                 hooks: baseParams.hooks
//             }),
//             lowerTick,
//             upperTick,
//             liquidity,
//             isLeftSide ? 0 : oneSidedParams.amount,
//             isLeftSide ? oneSidedParams.amount : 0,
//             baseParams.positionRecipient,
//             ParamsBuilder.ZERO_BYTES
//         );
//     }

//     function getLeftSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
//         private
//         pure
//         returns (TickBounds memory bounds)
//     {
//         int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

//         // Check if position is too close to MIN_TICK. If so, return a lower tick and upper tick of 0
//         if (initialTick - TickMath.MIN_TICK < poolTickSpacing) {
//             return bounds;
//         }

//         bounds = TickBounds({
//             lowerTick: TickMath.MIN_TICK / poolTickSpacing * poolTickSpacing, // Rounds to the nearest multiple of tick spacing (rounds towards 0 since MIN_TICK is negative)
//             upperTick: initialTick.tickFloor(poolTickSpacing) // Rounds to the nearest multiple of tick spacing if needed (rounds toward -infinity)
//         });

//         return bounds;
//     }

//     function getRightSideBounds(uint160 initialSqrtPriceX96, int24 poolTickSpacing)
//         private
//         pure
//         returns (TickBounds memory bounds)
//     {
//         int24 initialTick = TickMath.getTickAtSqrtPrice(initialSqrtPriceX96);

//         // Check if position is too close to MAX_TICK. If so, return a lower tick and upper tick of 0
//         if (TickMath.MAX_TICK - initialTick <= poolTickSpacing) {
//             return bounds;
//         }

//         bounds = TickBounds({
//             lowerTick: initialTick.tickStrictCeil(poolTickSpacing), // Rounds toward +infinity to the nearest multiple of tick spacing
//             upperTick: TickMath.MAX_TICK / poolTickSpacing * poolTickSpacing // Rounds to the nearest multiple of tick spacing (rounds toward 0 since MAX_TICK is positive)
//         });

//         return bounds;
//     }
// }
