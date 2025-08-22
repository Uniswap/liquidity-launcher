// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {MigratorParameters} from "../../../src/distributionContracts/LBPStrategyBasic.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract LBPTestDataBuilder {
    // Default values
    address constant DEFAULT_CURRENCY = address(0); // ETH
    uint24 constant DEFAULT_FEE = 500;
    int24 constant DEFAULT_TICK_SPACING = 1;
    uint16 constant DEFAULT_TOKEN_SPLIT = 5_000;
    address constant DEFAULT_POSITION_RECIPIENT = address(3);
    uint64 constant DEFAULT_MIGRATION_DELAY = 1_000;

    struct TestScenario {
        MigratorParameters params;
        uint128 totalSupply;
        uint128 initialTokenAmount;
        uint128 initialCurrencyAmount;
        bool expectRevert;
        bytes4 expectedError;
    }

    // Migrator params builder
    MigratorParameters private _params;
    address private _auctionFactory;

    constructor(address auctionFactory) {
        _auctionFactory = auctionFactory;
        _resetParams();
    }

    function withCurrency(address currency) external returns (LBPTestDataBuilder) {
        _params.currency = currency;
        return this;
    }

    function withFee(uint24 fee) external returns (LBPTestDataBuilder) {
        _params.fee = fee;
        return this;
    }

    function withTickSpacing(int24 tickSpacing) external returns (LBPTestDataBuilder) {
        _params.tickSpacing = tickSpacing;
        return this;
    }

    function withTokenSplit(uint16 tokenSplit) external returns (LBPTestDataBuilder) {
        _params.tokenSplitToAuction = tokenSplit;
        return this;
    }

    function withPositionRecipient(address recipient) external returns (LBPTestDataBuilder) {
        _params.positionRecipient = recipient;
        return this;
    }

    function withMigrationBlock(uint64 migrationBlock) external returns (LBPTestDataBuilder) {
        _params.migrationBlock = migrationBlock;
        return this;
    }

    function build() external returns (MigratorParameters memory) {
        MigratorParameters memory result = _params;
        _resetParams();
        return result;
    }

    function _resetParams() private {
        _params = MigratorParameters({
            currency: DEFAULT_CURRENCY,
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            tokenSplitToAuction: DEFAULT_TOKEN_SPLIT,
            auctionFactory: _auctionFactory,
            positionRecipient: DEFAULT_POSITION_RECIPIENT,
            migrationBlock: uint64(block.number + DEFAULT_MIGRATION_DELAY)
        });
    }

    // Test scenario generators
    function invalidFeeScenarios() external pure returns (TestScenario[] memory) {
        TestScenario[] memory scenarios = new TestScenario[](1);

        scenarios[0] = TestScenario({
            params: MigratorParameters({
                currency: DEFAULT_CURRENCY,
                fee: LPFeeLibrary.MAX_LP_FEE + 1,
                tickSpacing: DEFAULT_TICK_SPACING,
                tokenSplitToAuction: DEFAULT_TOKEN_SPLIT,
                auctionFactory: address(0), // Will be set by test
                positionRecipient: DEFAULT_POSITION_RECIPIENT,
                migrationBlock: 0 // Will be set by test
            }),
            totalSupply: 1_000e18,
            initialTokenAmount: 0,
            initialCurrencyAmount: 0,
            expectRevert: true,
            expectedError: bytes4(keccak256("InvalidFee(uint24)"))
        });

        return scenarios;
    }

    function invalidTickSpacingScenarios() external pure returns (TestScenario[] memory) {
        TestScenario[] memory scenarios = new TestScenario[](2);

        scenarios[0] = TestScenario({
            params: MigratorParameters({
                currency: DEFAULT_CURRENCY,
                fee: DEFAULT_FEE,
                tickSpacing: TickMath.MIN_TICK_SPACING - 1,
                tokenSplitToAuction: DEFAULT_TOKEN_SPLIT,
                auctionFactory: address(0),
                positionRecipient: DEFAULT_POSITION_RECIPIENT,
                migrationBlock: 0
            }),
            totalSupply: 1_000e18,
            initialTokenAmount: 0,
            initialCurrencyAmount: 0,
            expectRevert: true,
            expectedError: bytes4(keccak256("InvalidTickSpacing(int24)"))
        });

        scenarios[1] = TestScenario({
            params: MigratorParameters({
                currency: DEFAULT_CURRENCY,
                fee: DEFAULT_FEE,
                tickSpacing: TickMath.MAX_TICK_SPACING + 1,
                tokenSplitToAuction: DEFAULT_TOKEN_SPLIT,
                auctionFactory: address(0),
                positionRecipient: DEFAULT_POSITION_RECIPIENT,
                migrationBlock: 0
            }),
            totalSupply: 1_000e18,
            initialTokenAmount: 0,
            initialCurrencyAmount: 0,
            expectRevert: true,
            expectedError: bytes4(keccak256("InvalidTickSpacing(int24)"))
        });

        return scenarios;
    }

    function invalidPositionRecipientScenarios() external pure returns (TestScenario[] memory) {
        TestScenario[] memory scenarios = new TestScenario[](3);

        address[3] memory invalidRecipients = [address(0), address(1), address(2)];

        for (uint256 i = 0; i < 3; i++) {
            scenarios[i] = TestScenario({
                params: MigratorParameters({
                    currency: DEFAULT_CURRENCY,
                    fee: DEFAULT_FEE,
                    tickSpacing: DEFAULT_TICK_SPACING,
                    tokenSplitToAuction: DEFAULT_TOKEN_SPLIT,
                    auctionFactory: address(0),
                    positionRecipient: invalidRecipients[i],
                    migrationBlock: 0
                }),
                totalSupply: 1_000e18,
                initialTokenAmount: 0,
                initialCurrencyAmount: 0,
                expectRevert: true,
                expectedError: bytes4(keccak256("InvalidPositionRecipient(address)"))
            });
        }

        return scenarios;
    }

    function validMigrationScenarios() external pure returns (TestScenario[] memory) {
        TestScenario[] memory scenarios = new TestScenario[](3);

        // Full range position with ETH
        scenarios[0] = TestScenario({
            params: MigratorParameters({
                currency: DEFAULT_CURRENCY,
                fee: DEFAULT_FEE,
                tickSpacing: DEFAULT_TICK_SPACING,
                tokenSplitToAuction: DEFAULT_TOKEN_SPLIT,
                auctionFactory: address(0),
                positionRecipient: DEFAULT_POSITION_RECIPIENT,
                migrationBlock: 0
            }),
            totalSupply: 1_000e18,
            initialTokenAmount: 500e18,
            initialCurrencyAmount: 500e18,
            expectRevert: false,
            expectedError: bytes4(0)
        });

        // One-sided position with ETH
        scenarios[1] = TestScenario({
            params: MigratorParameters({
                currency: DEFAULT_CURRENCY,
                fee: DEFAULT_FEE,
                tickSpacing: DEFAULT_TICK_SPACING,
                tokenSplitToAuction: DEFAULT_TOKEN_SPLIT,
                auctionFactory: address(0),
                positionRecipient: DEFAULT_POSITION_RECIPIENT,
                migrationBlock: 0
            }),
            totalSupply: 1_000e18,
            initialTokenAmount: 250e18,
            initialCurrencyAmount: 500e18,
            expectRevert: false,
            expectedError: bytes4(0)
        });

        // Full range position with token (non-ETH)
        scenarios[2] = TestScenario({
            params: MigratorParameters({
                currency: address(0x6B175474E89094C44Da98b954EedeAC495271d0F), // DAI
                fee: DEFAULT_FEE,
                tickSpacing: 20,
                tokenSplitToAuction: DEFAULT_TOKEN_SPLIT,
                auctionFactory: address(0),
                positionRecipient: DEFAULT_POSITION_RECIPIENT,
                migrationBlock: 0
            }),
            totalSupply: 1_000e18,
            initialTokenAmount: 500e18,
            initialCurrencyAmount: 500e18,
            expectRevert: false,
            expectedError: bytes4(0)
        });

        return scenarios;
    }
}
