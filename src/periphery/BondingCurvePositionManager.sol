// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IBondingCurveLaunchHook} from "../interfaces/IBondingCurveLaunchHook.sol";
import {BondingCurveMath} from "../libraries/BondingCurveMath.sol";
import {PositionPlanner} from "../libraries/PositionPlanner.sol";
import {Position, CurrencyAmounts} from "../types/PositionPlannerTypes.sol";

/// @title BondingCurvePositionManager
/// @notice Holds one curve position and permissionlessly graduates it into full-range liquidity
/// @dev The curve NFT ID, reserve amount, price bounds, and recipients are fixed at deployment.
contract BondingCurvePositionManager is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address internal constant BURN_ADDRESS = address(0xdead);

    /// @notice Thrown after this manager has already graduated.
    error AlreadyGraduated();
    /// @notice Thrown when this manager does not own the configured curve NFT.
    error InvalidCurvePositionOwner();
    /// @notice Thrown when the configured assets cannot mint final liquidity.
    error InvalidFinalPosition();
    /// @notice Thrown when a required address is zero.
    error ZeroAddress();

    /// @notice Emitted after the curve NFT is replaced by a full-range NFT.
    /// @param curveTokenId The burned curve NFT ID.
    /// @param finalTokenId The newly minted full-range NFT ID.
    /// @param liquidity The liquidity minted into the final position.
    event Graduated(uint256 indexed curveTokenId, uint256 indexed finalTokenId, uint256 liquidity);

    /// @notice Token sold through the curve and reserved for graduation.
    IERC20 public immutable token;
    /// @notice v4 position manager used for both curve and final LP NFTs.
    IPositionManager public immutable positionManager;
    /// @notice Hook that authorizes and completes the graduation transition.
    IBondingCurveLaunchHook public immutable launchHook;
    /// @notice Curve NFT held by this manager until graduation.
    uint256 public immutable curveTokenId;
    /// @notice Fixed token reserve used to mint the final position.
    uint256 public immutable reserveTokenAmount;
    /// @notice Permanent recipient of the graduated full-range NFT.
    address public immutable finalPositionRecipient;
    /// @notice Square-root price at the start of the finite curve.
    uint160 public immutable initialSqrtPriceX96;
    /// @notice Square-root price at which graduation becomes available.
    uint160 public immutable graduationSqrtPriceX96;

    /// @notice Pool graduated by this manager.
    PoolKey public poolKey;
    /// @notice Whether the curve NFT has been replaced by the final NFT.
    bool public graduated;

    constructor(
        IERC20 _token,
        IPositionManager _positionManager,
        IBondingCurveLaunchHook _launchHook,
        PoolKey memory _poolKey,
        uint256 _curveTokenId,
        uint256 _reserveTokenAmount,
        address _finalPositionRecipient,
        uint160 _initialSqrtPriceX96,
        uint160 _graduationSqrtPriceX96
    ) {
        // Every collaborator and recipient is fixed for this launch.
        if (
            address(_token) == address(0) || address(_positionManager) == address(0)
                || address(_launchHook) == address(0) || _finalPositionRecipient == address(0)
        ) revert ZeroAddress();

        token = _token;
        positionManager = _positionManager;
        launchHook = _launchHook;
        poolKey = _poolKey;
        curveTokenId = _curveTokenId;
        reserveTokenAmount = _reserveTokenAmount;
        finalPositionRecipient = _finalPositionRecipient;
        initialSqrtPriceX96 = _initialSqrtPriceX96;
        graduationSqrtPriceX96 = _graduationSqrtPriceX96;
    }

    /// @notice Replaces the completed curve position with a permanently owned full-range position
    function graduate() external nonReentrant {
        // Graduation is one-shot and requires custody of the original curve NFT.
        if (graduated) revert AlreadyGraduated();
        if (IERC721(address(positionManager)).ownerOf(curveTokenId) != address(this)) {
            revert InvalidCurvePositionOwner();
        }

        uint128 curveLiquidity = positionManager.getPositionLiquidity(curveTokenId);
        uint256 principal =
            BondingCurveMath.completedCurvePrincipal(curveLiquidity, graduationSqrtPriceX96, initialSqrtPriceX96);
        Position memory finalPosition = PositionPlanner.resolvePosition(
            PositionPlanner.TickBounds({
                lowerTick: TickMath.minUsableTick(poolKey.tickSpacing),
                upperTick: TickMath.maxUsableTick(poolKey.tickSpacing)
            }),
            graduationSqrtPriceX96,
            Pool.tickSpacingToMaxLiquidityPerTick(poolKey.tickSpacing),
            CurrencyAmounts({amount0: principal, amount1: reserveTokenAmount}),
            finalPositionRecipient
        );
        if (finalPosition.liquidity == 0) revert InvalidFinalPosition();

        // The hook verifies the terminal price before allowing the atomic position replacement.
        graduated = true;
        launchHook.beginGraduation(poolKey);

        // PositionManager settles the reserved tokens during the same atomic plan.
        token.safeTransfer(address(positionManager), reserveTokenAmount);
        uint256 finalTokenId = positionManager.nextTokenId();
        positionManager.modifyLiquidities(_graduationPlan(finalPosition), block.timestamp);

        // Sweep launch rounding dust without relying on it for graduation accounting.
        uint256 remainingToken = token.balanceOf(address(this));
        if (remainingToken != 0) token.safeTransfer(BURN_ADDRESS, remainingToken);
        uint256 remainingNative = address(this).balance;
        if (remainingNative != 0) SafeTransferLib.safeTransferETH(finalPositionRecipient, remainingNative);

        emit Graduated(curveTokenId, finalTokenId, finalPosition.liquidity);
    }

    receive() external payable {}

    function _graduationPlan(Position memory finalPosition) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.BURN_POSITION),
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE),
            uint8(Actions.SETTLE),
            uint8(Actions.TAKE),
            uint8(Actions.TAKE)
        );
        bytes[] memory params = new bytes[](6);
        params[0] = abi.encode(curveTokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(
            poolKey,
            finalPosition.tickLower,
            finalPosition.tickUpper,
            finalPosition.liquidity,
            SafeCastLib.toUint128(finalPosition.amount0),
            SafeCastLib.toUint128(finalPosition.amount1),
            finalPositionRecipient,
            bytes("")
        );
        params[2] = abi.encode(poolKey.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(poolKey.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[4] = abi.encode(poolKey.currency0, finalPositionRecipient, ActionConstants.OPEN_DELTA);
        params[5] = abi.encode(poolKey.currency1, BURN_ADDRESS, ActionConstants.OPEN_DELTA);
        return abi.encode(actions, params);
    }
}
