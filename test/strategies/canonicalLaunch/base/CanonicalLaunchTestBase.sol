// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {CanonicalLaunchStrategy} from "../../../../src/strategies/CanonicalLaunchStrategy.sol";
import {DirectLaunchStrategy} from "../../../../src/strategies/DirectLaunchStrategy.sol";
import {MockERC20} from "../../../mocks/MockERC20.sol";

contract MockCanonicalDirectLaunchStrategy {
    using SafeERC20 for IERC20;

    IPositionManager public immutable positionManager;
    address public lastToken;
    uint256 public lastTotalSupply;
    bytes public lastConfigData;
    bytes32 public lastSalt;
    uint256 public pullShortfall;
    uint256 public returnAmount;

    constructor(IPositionManager _positionManager) {
        positionManager = _positionManager;
    }

    function setBehavior(uint256 _pullShortfall, uint256 _returnAmount) external {
        pullShortfall = _pullShortfall;
        returnAmount = _returnAmount;
    }

    function initializeDistribution(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt)
        external
    {
        lastToken = token;
        lastTotalSupply = totalSupply;
        lastConfigData = configData;
        lastSalt = salt;

        IERC20(token).safeTransferFrom(msg.sender, address(this), totalSupply - pullShortfall);
        if (returnAmount != 0) IERC20(token).safeTransfer(msg.sender, returnAmount);
    }
}

contract MockCanonicalSixDecimalToken is ERC20 {
    constructor(uint256 supply, address recipient) ERC20("Six Decimal Token", "SIX") {
        _mint(recipient, supply);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockCanonicalShortTransferToken is ERC20 {
    constructor(uint256 supply, address recipient) ERC20("Short Transfer Token", "SHORT") {
        _mint(recipient, supply);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _spendAllowance(from, _msgSender(), value);
        _transfer(from, to, value - 1);
        return true;
    }
}

abstract contract CanonicalLaunchTestBase is Test {
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000 ether;
    int24 internal constant INITIAL_TICK = 122_000;
    address internal constant BURN_ADDRESS = address(0xdead);

    address internal launcher = address(this);
    address internal launchHook = makeAddr("launchHook");
    address internal dynamicFeeModule = makeAddr("dynamicFeeModule");
    IPositionManager internal positionManager = IPositionManager(makeAddr("positionManager"));

    MockCanonicalDirectLaunchStrategy internal directLaunchStrategy;
    CanonicalLaunchStrategy internal strategy;

    function setUp() public virtual {
        directLaunchStrategy = new MockCanonicalDirectLaunchStrategy(positionManager);
        strategy = _deployStrategy(INITIAL_TICK);
    }

    function _deployStrategy(int24 initialTick) internal returns (CanonicalLaunchStrategy) {
        return new CanonicalLaunchStrategy(
            launcher,
            DirectLaunchStrategy(payable(address(directLaunchStrategy))),
            launchHook,
            dynamicFeeModule,
            initialTick
        );
    }

    function _deployToken(uint256 supply) internal returns (MockERC20) {
        return new MockERC20("Canonical Token", "CAN", supply, address(this));
    }

    function _initialize(IERC20 token, uint256 totalSupply, bytes memory configData) internal {
        token.approve(address(strategy), totalSupply);
        strategy.initializeDistribution(address(token), totalSupply, configData, bytes32(uint256(1)));
    }
}
