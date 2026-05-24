// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {UERC20Factory} from "@uniswap/uerc20-factory/src/factories/UERC20Factory.sol";
import {UERC20Metadata} from "@uniswap/uerc20-factory/src/libraries/UERC20MetadataLibrary.sol";
import {LiquidityLauncher} from "src/LiquidityLauncher.sol";
import {Distribution} from "src/types/Distribution.sol";
import {IDistributionContract} from "src/interfaces/IDistributionContract.sol";
import {IDistributionStrategy} from "src/interfaces/IDistributionStrategy.sol";
import {MockDistributionStrategyAndContract} from "./mocks/MockDistributionStrategyAndContract.sol";

contract TheftStrategy is IDistributionStrategy, IDistributionContract {
    using SafeERC20 for IERC20;

    address public immutable thief;

    constructor(address _thief) {
        thief = _thief;
    }

    function initializeDistribution(address token, uint256 amount, bytes calldata, bytes32)
        external
        override
        returns (IDistributionContract distributionContract)
    {
        IERC20(token).safeTransferFrom(msg.sender, thief, amount);
        return IDistributionContract(address(this));
    }

    function onTokensReceived() external override {}
}

contract MaliciousReentrantToken is ERC20 {
    enum AttackSurface {
        None,
        TransferFrom,
        Approve
    }

    LiquidityLauncher public immutable launcher;
    IAllowanceTransfer public immutable permit2;

    address public immutable targetToken;
    address public immutable stealStrategy;
    AttackSurface public immutable attackSurface;
    bool public armed;

    constructor(
        LiquidityLauncher _launcher,
        IAllowanceTransfer _permit2,
        address initialHolder,
        uint256 initialSupply,
        address _targetToken,
        address _stealStrategy,
        AttackSurface _attackSurface
    ) ERC20("Malicious Token", "MAL") {
        launcher = _launcher;
        permit2 = _permit2;
        targetToken = _targetToken;
        stealStrategy = _stealStrategy;
        attackSurface = _attackSurface;
        armed = true;
        _mint(initialHolder, initialSupply);
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        _maybeAttack(AttackSurface.Approve);
        return super.approve(spender, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        _maybeAttack(AttackSurface.TransferFrom);
        return super.transferFrom(from, to, value);
    }

    function _maybeAttack(AttackSurface expectedSurface) internal {
        if (!armed || attackSurface != expectedSurface) return;
        if (expectedSurface == AttackSurface.TransferFrom && msg.sender != address(permit2)) return;
        if (expectedSurface == AttackSurface.Approve && msg.sender != address(launcher)) return;

        armed = false;

        uint128 stealAmount = uint128(IERC20(targetToken).balanceOf(address(launcher)));
        Distribution memory distribution = Distribution({strategy: stealStrategy, amount: stealAmount, configData: ""});
        launcher.distributeToken(targetToken, distribution, keccak256("reentrant-steal"));
    }
}

contract LiquidityLauncherReentrancyTest is Test, DeployPermit2 {
    LiquidityLauncher internal launcher;
    IAllowanceTransfer internal permit2;
    UERC20Factory internal uerc20Factory;

    address internal victim;
    address internal attacker;

    uint128 internal constant VICTIM_TOKEN_SUPPLY = 1_000_000e18;
    uint160 internal constant MALICIOUS_TOKEN_SUPPLY = 250_000e18;

    function setUp() public {
        permit2 = IAllowanceTransfer(deployPermit2());
        launcher = new LiquidityLauncher(permit2);
        uerc20Factory = new UERC20Factory();

        victim = makeAddr("victim");
        attacker = makeAddr("attacker");
    }

    function test_reentrantTransferFromCannotDistributeUnrelatedStagedBalance() public {
        address victimToken = _precomputeVictimTokenAddress(victim, "Victim Token A", "VTA");
        MockDistributionStrategyAndContract honestStrategy = new MockDistributionStrategyAndContract();
        MaliciousReentrantToken maliciousToken =
            _deployMaliciousToken(victimToken, MaliciousReentrantToken.AttackSurface.TransferFrom);
        _approvePermit2ForVictim(maliciousToken);

        bytes[] memory calls = _buildVictimBatch(maliciousToken, honestStrategy, "Victim Token A", "VTA");

        vm.expectRevert("TRANSFER_FROM_FAILED");
        vm.prank(victim);
        launcher.multicall(calls);
    }

    function test_reentrantApproveCannotDistributeUnrelatedStagedBalance() public {
        address victimToken = _precomputeVictimTokenAddress(victim, "Victim Token B", "VTB");
        MockDistributionStrategyAndContract honestStrategy = new MockDistributionStrategyAndContract();
        MaliciousReentrantToken maliciousToken =
            _deployMaliciousToken(victimToken, MaliciousReentrantToken.AttackSurface.Approve);
        _approvePermit2ForVictim(maliciousToken);

        bytes[] memory calls = _buildVictimBatch(maliciousToken, honestStrategy, "Victim Token B", "VTB");

        vm.expectRevert(ReentrancyGuardTransient.Reentrancy.selector);
        vm.prank(victim);
        launcher.multicall(calls);
    }

    function _deployMaliciousToken(address victimToken, MaliciousReentrantToken.AttackSurface attackSurface)
        internal
        returns (MaliciousReentrantToken maliciousToken)
    {
        vm.startPrank(attacker);
        TheftStrategy theftStrategy = new TheftStrategy(attacker);
        maliciousToken = new MaliciousReentrantToken(
            launcher, permit2, attacker, MALICIOUS_TOKEN_SUPPLY, victimToken, address(theftStrategy), attackSurface
        );
        maliciousToken.transfer(victim, MALICIOUS_TOKEN_SUPPLY);
        vm.stopPrank();
    }

    function _approvePermit2ForVictim(MaliciousReentrantToken maliciousToken) internal {
        vm.startPrank(victim);
        maliciousToken.approve(address(permit2), type(uint256).max);
        permit2.approve(
            address(maliciousToken), address(launcher), MALICIOUS_TOKEN_SUPPLY, uint48(block.timestamp + 1 days)
        );
        vm.stopPrank();
    }

    function _buildVictimBatch(
        MaliciousReentrantToken maliciousToken,
        MockDistributionStrategyAndContract honestStrategy,
        string memory victimTokenName,
        string memory victimTokenSymbol
    ) internal view returns (bytes[] memory calls) {
        UERC20Metadata memory metadata = UERC20Metadata({
            description: "victim token created through the real launcher flow",
            website: "https://example.com",
            image: "https://example.com/token.png",
            xProofTweetId: 0
        });

        Distribution memory honestDistribution =
            Distribution({strategy: address(honestStrategy), amount: uint128(MALICIOUS_TOKEN_SUPPLY), configData: ""});

        calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(
            LiquidityLauncher.createToken.selector,
            address(uerc20Factory),
            victimTokenName,
            victimTokenSymbol,
            18,
            VICTIM_TOKEN_SUPPLY,
            address(launcher),
            abi.encode(metadata)
        );
        calls[1] = abi.encodeWithSelector(
            LiquidityLauncher.depositToken.selector, address(maliciousToken), MALICIOUS_TOKEN_SUPPLY
        );
        calls[2] = abi.encodeWithSelector(
            LiquidityLauncher.distributeToken.selector, address(maliciousToken), honestDistribution, bytes32("legit")
        );
    }

    function _precomputeVictimTokenAddress(address creator, string memory name, string memory symbol)
        internal
        view
        returns (address)
    {
        return uerc20Factory.getUERC20Address(name, symbol, 18, address(launcher), launcher.getGraffiti(creator));
    }
}
