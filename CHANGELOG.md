# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking changes
- `BuybackAndBurnClaimRecipient` now burns `currency0` or `currency1`, selected by the new `burnCurrency0` immutable; `minCurrency1BurnAmount` is renamed to `minBurnAmount`, and the native-ETH `currency0` requirement is replaced by a check that the burn currency is an ERC20 [#246](https://github.com/Uniswap/token-launcher/pull/246)

## [3.2.0]

### Breaking changes
- `PositionFeesForwarder` removed; instant launch positions are permanently locked in the `FeeSplitter` singleton instead [#192](https://github.com/Uniswap/token-launcher/pull/192)
- `BuybackAndBurnPositionRecipient` replaced by `BuybackAndBurnClaimRecipient` on the callback-based claim recipient framework; periphery recipients expose `claim` instead of `collectFees` [#196](https://github.com/Uniswap/token-launcher/pull/196), [#207](https://github.com/Uniswap/token-launcher/pull/207), [#208](https://github.com/Uniswap/token-launcher/pull/208)

### Added
- `InstantLaunchStrategy` for fixed-supply, hookless native-ETH v4 pool launches with a single-sided LP position permanently locked in the fee splitter [#184](https://github.com/Uniswap/token-launcher/pull/184), [#191](https://github.com/Uniswap/token-launcher/pull/191), [#192](https://github.com/Uniswap/token-launcher/pull/192)
- `FeeSplitter` singleton that permissionlessly collects and distributes native-ETH and token fees across immutable splits [#192](https://github.com/Uniswap/token-launcher/pull/192)
- `BeneficiaryVault` and transferable fee-beneficiary ERC721 for creator fee registration and claims [#201](https://github.com/Uniswap/token-launcher/pull/201)
- Callback-based claim recipients: `BaseClaimRecipient`, `BaseClaimRecipientWithCallback`, `CompoundingClaimRecipient`, and singleton `BuybackAndBurnClaimRecipient` [#196](https://github.com/Uniswap/token-launcher/pull/196), [#189](https://github.com/Uniswap/token-launcher/pull/189)
- `UERC20BeneficiaryVault` so UERC20 creators can register unregistered positions via graffiti proof [#211](https://github.com/Uniswap/token-launcher/pull/211)
- `UniversalRouterStrategy` and `LiquidityLauncher.distributeWithNative` to run a caller-supplied Universal Router route so a launch and buy fit in one transaction [#223](https://github.com/Uniswap/token-launcher/pull/223)
- Deployment scripts for instant launch, universal router, fee splitter, and periphery contracts [#200](https://github.com/Uniswap/token-launcher/pull/200)

### Changed
- Raised the compounding claim recipient floor to 1e20 [#217](https://github.com/Uniswap/token-launcher/pull/217)
- `InstantLaunchStrategy` uses tick spacing 25 to match the 25 bps LP fee, with `MIN_LAUNCH_TICK` at -160,100 and `MAX_INITIAL_TICK` at 251,325; deployed initial ticks must be multiples of 25 and the deployment script's tick moves from 198,060 to 198,050 [#230](https://github.com/Uniswap/token-launcher/pull/230)
- Deploy scripts read the `LiquidityLauncher` address from env [#232](https://github.com/Uniswap/token-launcher/pull/232)

### Fixed
- Added `receive()` on `InstantLaunchStrategy` so stray ETH forwarded from the PositionManager does not brick the contract [#197](https://github.com/Uniswap/token-launcher/pull/197)
- Enforced a verifiable, freely chosen fee beneficiary for launcher-created tokens [#192](https://github.com/Uniswap/token-launcher/pull/192)
- Reverted `FeeSplitter.collectFees` when a recipient's fee notification fails [#209](https://github.com/Uniswap/token-launcher/pull/209)
- Resolved OpenZeppelin audit notes N04–N09 and L-04 [#218](https://github.com/Uniswap/token-launcher/pull/218)
- Fixed graffiti-based registration in `UERC20BeneficiaryVault` [#226](https://github.com/Uniswap/token-launcher/pull/226)
- Removed the approval check in `FeeSplitter` distribution [#233](https://github.com/Uniswap/token-launcher/pull/233)

### Removed
- `PositionFeesForwarder` (superseded by `FeeSplitter`) [#192](https://github.com/Uniswap/token-launcher/pull/192)
- `BuybackAndBurnPositionRecipient` (superseded by `BuybackAndBurnClaimRecipient`) [#196](https://github.com/Uniswap/token-launcher/pull/196)

## [3.0.0]
Token Launcher v3.0.0 is a major release with breaking changes. It is not backwards compatible with v2.0.0.

### Breaking changes
- `distributeToken` now uses a pull model: removed the `payerIsUser` parameter and the `IDistributionContract` return value. Acquire tokens with `createToken` or the new `depositToken`, then batch with `distributeToken` in a single `multicall`. The launcher force-approves the strategy, which pulls the full amount via `safeTransferFrom`, and reverts with `AllowanceNotFullyConsumed` if it does not. The `TokenDistributed` event's `distributionContract` argument is renamed `strategy` [#141](https://github.com/Uniswap/token-launcher/pull/141), [#160](https://github.com/Uniswap/token-launcher/pull/160)
- Consolidated all LBP strategy variants (`LBPStrategyBase`, `AdvancedLBPStrategy`, `FullRangeLBPStrategy`, `GovernedLBPStrategy`, `VirtualGovernedLBPStrategy`) into a single `LBPStrategy`; removed all per-variant strategy factories and the `StrategyFactory` base [#141](https://github.com/Uniswap/token-launcher/pull/141)
- Interface renames: `IDistributionStrategy` → `IStrategy`, `IDistributionContract` → `IDistributor`, `ILBPStrategyBase` → `ILBPStrategy`. `IStrategy.initializeDistribution` no longer returns a contract; the strategy is now responsible for pulling tokens from the caller [#150](https://github.com/Uniswap/token-launcher/pull/150), [#152](https://github.com/Uniswap/token-launcher/pull/152)
- `MigratorParameters` reworked and moved to `src/libraries/MigratorParams.sol`: replaced single full-range migration with a weighted `positionDefinitions` plan, a bracketed `lpAllocationSchedule` with up to 32 brackets, and a `positionRecipient` (with optional per-position `overridePositionRecipient`) [#160](https://github.com/Uniswap/token-launcher/pull/160), [#159](https://github.com/Uniswap/token-launcher/pull/159), [#171](https://github.com/Uniswap/token-launcher/pull/171)
- Replaced the per-LBP `ProtocolFeeOperator` (EIP-1167 clone) with a single governance-owned `ProtocolFeeController` exposing bracketed per-currency fees via `IProtocolFeeController` [#139](https://github.com/Uniswap/token-launcher/pull/139), [#146](https://github.com/Uniswap/token-launcher/pull/146)

Integrators should update to v3.0.0 as soon as possible.

### Added
- `migrate(initializer)` best-effort migration: the public entrypoint wraps a self-call helper, emits `MigrationFailed` on migration failure, and recovers raised currency plus reserved LP tokens to the configured recipient in the same transaction [#151](https://github.com/Uniswap/token-launcher/pull/151), [#160](https://github.com/Uniswap/token-launcher/pull/160), [#174](https://github.com/Uniswap/token-launcher/pull/174)
- `PositionPlanner` library for weighted, multi-position liquidity migration with a bracketed currency-to-LP allocation schedule [#128](https://github.com/Uniswap/token-launcher/pull/128), [#160](https://github.com/Uniswap/token-launcher/pull/160)
- Per-position LP NFT recipients via `overridePositionRecipient` [#159](https://github.com/Uniswap/token-launcher/pull/159)
- Pluggable migration hooks: new `InitializerHook` base (gates pool initialization) and `IInitializerHook`, plus an example `GatedSwapHook`. Caller-provided hooks MUST inherit `InitializerHook`, and dynamic-fee pools now require a hook [#134](https://github.com/Uniswap/token-launcher/pull/134), [#155](https://github.com/Uniswap/token-launcher/pull/155)
- Hookless static-fee LBP migrations prefer the canonical hookless v4 pool and fall back to the strategy-hooked pool if the hookless pool has already been initialized [#160](https://github.com/Uniswap/token-launcher/pull/160), [#164](https://github.com/Uniswap/token-launcher/pull/164)
- `depositToken(token, amount)` to pull pre-existing tokens via Permit2 for batching with `distributeToken` [#160](https://github.com/Uniswap/token-launcher/pull/160)
- `ILBPInitializer.sweepCurrency` / `sweepUnsoldTokens`; the strategy enforces that swept currency equals the initializer's reported `currencyRaised` [#160](https://github.com/Uniswap/token-launcher/pull/160)
- `IDistributorFactory` interface for factories that deploy distributors, including sender-aware `getAddress(...)` for factories whose deterministic address depends on the caller [#150](https://github.com/Uniswap/token-launcher/pull/150), [#163](https://github.com/Uniswap/token-launcher/pull/163)
- `TokenSplitter` strategy, `ITokenSplitter`, tests, and deployment script for direct split distributions that do not retain custody of funds in the strategy [#166](https://github.com/Uniswap/token-launcher/pull/166)

### Changed
- Raised the LP allocation schedule cap from 3 brackets to 32 brackets [#171](https://github.com/Uniswap/token-launcher/pull/171)
- `ProtocolFeeLib.getProtocolFeeAmount` now returns zero if the configured protocol fee controller reverts [#162](https://github.com/Uniswap/token-launcher/pull/162)

### Fixed
- Guard `LBPStrategy` against hook reentrancy corrupting migration state [#154](https://github.com/Uniswap/token-launcher/pull/154)
- Reserve target pool IDs during LBP initialization and clear them during migration to prevent pool-key conflicts and initializer replay [#164](https://github.com/Uniswap/token-launcher/pull/164)
- Validate migration hooks against v4 hook address rules, `BEFORE_INITIALIZE` permission bits, strategy authorization, and target pool initialization state [#167](https://github.com/Uniswap/token-launcher/pull/167)
- Force-send native-currency migration leftovers and `TAKE_PAIR` dust to recipients so a reverting recipient cannot grief migration [#161](https://github.com/Uniswap/token-launcher/pull/161), [#172](https://github.com/Uniswap/token-launcher/pull/172)
- Reject zero and PositionManager sentinel addresses as immutable `PositionFeesForwarder` fee recipients [#169](https://github.com/Uniswap/token-launcher/pull/169)
- Reject zero-weight positions and roll skipped allocation weight into the full-range fallback [#158](https://github.com/Uniswap/token-launcher/pull/158)
- Bind the LBP initializer deployment salt to the migrator parameters [#140](https://github.com/Uniswap/token-launcher/pull/140)
- Document the trusted-owner `MerkleClaim` claim/withdraw overlap at exactly `endTime` while retaining upstream merkle-distributor behavior [#170](https://github.com/Uniswap/token-launcher/pull/170)
- Reject migrations where the launched token and auction currency are the same asset
- Revert migration when no positions are created

### Removed
- Strategy factory contracts (`StrategyFactory`, `AdvancedLBPStrategyFactory`, `FullRangeLBPStrategyFactory`, `GovernedLBPStrategyFactory`) and the per-variant LBP strategies [#141](https://github.com/Uniswap/token-launcher/pull/141)
- `ProtocolFeeOperator` [#139](https://github.com/Uniswap/token-launcher/pull/139)
- `IDistributionContract` and `IStrategyFactory` interfaces [#150](https://github.com/Uniswap/token-launcher/pull/150)
- `recoverFunds` (superseded by inline `migrate` recovery) [#160](https://github.com/Uniswap/token-launcher/pull/160)

## [2.0.0]
Liquidity Launcher v2.0.0 is a major release with breaking changes. It is not backwards compatible with v1.0.0.

### Breaking changes
- Renaming of existing contracts (strategies and factories)
- Addition of `maxCurrencyAmountForLP` parameter to `MigratorParameters` struct
- `ILBPInitializer` interface is used instead of the original direct integration with `IContinuousClearingAuction`
- Significant directory structure changes

Integrators should update to v2.0.0 as soon as possible.

### Added
- Refactored strategies to be more extensible and reusable [#84](https://github.com/Uniswap/liquidity-launcher/pull/84)
- New base strategy contract: LBPStrategyBase
- New strategy contracts: FullRangeLBPStrategy, AdvancedLBPStrategy, GovernedLBPStrategy, VirtualLBPStrategy
- Refactored strategy contracts to inherit from StrategyFactory
- New strategy factory contracts: FullRangeLBPStrategyFactory, AdvancedLBPStrategyFactory, GovernedLBPStrategyFactory [#87](https://github.com/Uniswap/liquidity-launcher/pull/87)
- `maxCurrencyAmountForLP` parameter to the strategy contracts [#99](https://github.com/Uniswap/liquidity-launcher/pull/99)
- New `ILBPInitializer` interface for LBP initializers [#83](https://github.com/Uniswap/liquidity-launcher/pull/83)
- BTT unit testing suite [#96](https://github.com/Uniswap/liquidity-launcher/pull/96)
- Periphery position recipient contracts: TimeLockedPositionRecipient, PositionFeesForwarder, BuybackAndBurnPositionRecipient [#82](https://github.com/Uniswap/liquidity-launcher/pull/82)
- Documentation: Deployment Guide, Technical Reference [#110](https://github.com/Uniswap/liquidity-launcher/pull/110)

### Fixed
- Fixed missing `DistributionInitialized` event [#94](https://github.com/Uniswap/liquidity-launcher/pull/94)

### Removed
- Old strategy contracts: LBPStrategyBasic, VirtualLBPStrategyBasic
- Local clone of uerc20-factory contracts repo [#97](https://github.com/Uniswap/liquidity-launcher/pull/97)
- Outdated OZ dependency [#97](https://github.com/Uniswap/liquidity-launcher/pull/97)

## [1.0.0]

### Added
- Initial release of Liquidity Launcher.

### Fixed
N/A
