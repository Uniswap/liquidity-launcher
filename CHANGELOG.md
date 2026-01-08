# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0]
### Added
- Refactored strategies to be more extensible and reusable [#84](https://github.com/Uniswap/liquidity-launcher/pull/84)
- New base strategy contract: LBPStrategyBase
- New strategy contracts: FullRangeLBPStrategy, AdvancedLBPStrategy, GovernedLBPStrategy, VirtualLBPStrategy
- Refactored strategy contracts to inherit from StrategyFactory
- New strategy factory contracts: FullRangeLBPStrategyFactory, AdvancedLBPStrategyFactory, GovernedLBPStrategyFactory [#87](https://github.com/Uniswap/liquidity-launcher/pull/87)
- `maxCurrencyAmountForLP` parameter to the strategy contracts [#99](https://github.com/Uniswap/liquidity-launcher/pull/99)
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