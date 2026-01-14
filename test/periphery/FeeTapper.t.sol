// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeTapper} from "../../src/periphery/FeeTapper.sol";
import {IFeeTapper} from "../../src/interfaces/periphery/IFeeTapper.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Mock} from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract FeeTapperTest is Test {
    using CurrencyLibrary for Currency;

    FeeTapper public feeTapper;
    address public tokenJar = makeAddr("tokenJar");
    address public owner = makeAddr("owner");

    ERC20Mock public erc20Currency;

    uint24 public constant BPS = 10_000;

    function setUp() public {
        feeTapper = new FeeTapper(tokenJar, owner);
        vm.deal(address(this), type(uint256).max);
        erc20Currency = new ERC20Mock();
    }

    function _deal(address to, uint256 amount, bool useNativeCurrency) internal {
        if (useNativeCurrency) {
            _dealETH(to, amount);
        } else {
            _dealERC20(to, amount);
        }
    }

    function _dealETH(address to, uint256 amount) internal {
        (bool success,) = address(to).call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function _dealERC20(address to, uint256 amount) internal {
        erc20Currency.mint(to, amount);
    }

    function test_setPerBlockReleaseRate_reverts_notOwner(uint24 _perBlockReleaseRate) public {
        address notOwner = makeAddr("notOwner");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        vm.prank(notOwner);
        feeTapper.setReleaseRate(_perBlockReleaseRate);
    }

    function test_setReleaseRate_WhenEqZero() public {
        // it reverts with {InvalidReleaseRate()}

        vm.prank(owner);
        vm.expectRevert(IFeeTapper.InvalidReleaseRate.selector);
        feeTapper.setReleaseRate(0);
    }

    function test_setReleaseRate_WhenGtBPS(uint24 _perBlockReleaseRate) public {
        // it reverts with {InvalidReleaseRate()}

        _perBlockReleaseRate = uint24(bound(_perBlockReleaseRate, BPS + 1, type(uint24).max));

        vm.prank(owner);
        vm.expectRevert(IFeeTapper.InvalidReleaseRate.selector);
        feeTapper.setReleaseRate(_perBlockReleaseRate);
    }

    function test_setReleaseRate_WhenLTEBPS(uint24 _perBlockReleaseRate) public {
        // it succeeds

        _perBlockReleaseRate = uint24(bound(_perBlockReleaseRate, 1, BPS));

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit IFeeTapper.ReleaseRateSet(_perBlockReleaseRate);
        feeTapper.setReleaseRate(_perBlockReleaseRate);
        assertEq(feeTapper.perBlockReleaseRate(), _perBlockReleaseRate);
    }

    function test_sync_WhenCurrencyIsNotAddressZero(uint128 _feeAmount) public {
        // it emits a {Synced()} event

        _feeAmount = uint128(bound(_feeAmount, 1, type(uint128).max / feeTapper.perBlockReleaseRate()));

        Currency currency = Currency.wrap(address(erc20Currency));

        deal(address(erc20Currency), address(feeTapper), _feeAmount);

        vm.expectEmit(true, true, true, true);
        emit IFeeTapper.Synced(Currency.unwrap(currency), _feeAmount);
        feeTapper.sync(currency);
        assertEq(feeTapper.taps(currency).balance, _feeAmount);
    }

    function test_sync_WhenCurrencyIsAddressZeroAndTapIsNotEmpty(
        uint128 _feeAmount,
        uint128 _additionalFeeAmount,
        uint64 _elapsed,
        bool _useNativeCurrency
    ) public {
        // it adds fee amount to the tap amount
        // it updates the release rate
        // it updates the last release block
        // it emits a {Synced()} event

        // Low bounds to avoid overflows later on
        _feeAmount = uint128(bound(_feeAmount, 1, type(uint64).max));
        _additionalFeeAmount = uint128(bound(_additionalFeeAmount, 1, type(uint64).max));

        Currency currency = _useNativeCurrency ? Currency.wrap(address(0)) : Currency.wrap(address(erc20Currency));
        _deal(address(feeTapper), _feeAmount, _useNativeCurrency);
        feeTapper.sync(currency);
        assertEq(feeTapper.taps(currency).balance, _feeAmount);

        _deal(address(feeTapper), _additionalFeeAmount, _useNativeCurrency);
        feeTapper.sync(currency);
        assertEq(feeTapper.taps(currency).balance, _feeAmount + _additionalFeeAmount);

        _elapsed = uint64(bound(_elapsed, 1, BPS / feeTapper.perBlockReleaseRate()));

        vm.roll(block.number + _elapsed);
        uint256 released = feeTapper.release(currency);
        assertEq(released, (_feeAmount + _additionalFeeAmount) * feeTapper.perBlockReleaseRate() * _elapsed / BPS);
    }

    function test_release_WhenTapAmountIsZero(Currency currency) public {
        // it returns 0

        uint256 amount = feeTapper.release(currency);
        assertEq(amount, 0);
    }

    function test_release_WhenElapsedIsZero(uint128 _feeAmount) public {
        // it returns 0

        _feeAmount = uint128(bound(_feeAmount, 1, type(uint128).max / feeTapper.perBlockReleaseRate()));

        Currency currency = Currency.wrap(address(0));
        _deal(address(feeTapper), _feeAmount, true);
        feeTapper.sync(currency);

        assertEq(feeTapper.taps(currency).balance, _feeAmount);

        uint256 amount = feeTapper.release(currency);
        assertEq(amount, 0);
    }

    function test_release_WhenToReleaseIsGreaterThanTapAmount(uint128 _feeAmount, uint64 _elapsed) public {
        // it returns the rest of the tap amount

        _elapsed = uint64(bound(_elapsed, BPS / feeTapper.perBlockReleaseRate(), type(uint64).max));
        _feeAmount = uint128(bound(_feeAmount, 1, type(uint128).max / feeTapper.perBlockReleaseRate() / _elapsed));

        Currency currency = Currency.wrap(address(0));
        _deal(address(feeTapper), _feeAmount, true);
        feeTapper.sync(currency);

        // ensure that there is more to release than the tap amount
        vm.roll(block.number + _elapsed);

        uint256 amount = feeTapper.release(currency);
        assertEq(amount, _feeAmount);
        assertEq(feeTapper.taps(currency).balance, 0);
    }

    function test_release_WhenToReleaseIsLTEThanTapAmount(uint128 _feeAmount, uint64 _elapsed, bool _useNativeCurrency)
        public
    {
        // it updates the tap amount
        // it emits a {Released()} event

        _elapsed = uint64(bound(_elapsed, 1, BPS / feeTapper.perBlockReleaseRate()));
        _feeAmount = uint128(bound(_feeAmount, 1, type(uint128).max / feeTapper.perBlockReleaseRate() / _elapsed));

        Currency currency = _useNativeCurrency ? Currency.wrap(address(0)) : Currency.wrap(address(erc20Currency));
        _deal(address(feeTapper), _feeAmount, _useNativeCurrency);
        feeTapper.sync(currency);

        assertEq(feeTapper.taps(currency).balance, _feeAmount);

        vm.roll(block.number + _elapsed);
        vm.expectEmit(true, true, true, true);
        uint128 expectedReleased = (_feeAmount * feeTapper.perBlockReleaseRate() * _elapsed) / BPS;
        emit IFeeTapper.Released(Currency.unwrap(currency), expectedReleased);
        vm.assume(expectedReleased > 0);
        uint128 released = feeTapper.release(currency);
        assertEq(released, expectedReleased);
        assertEq(feeTapper.taps(currency).balance, _feeAmount - released);
    }

    function test_release_IsLinear(uint128 _feeAmount, bool _useNativeCurrency) public {
        // it releases the amount of protocol fees based on the release rate

        _feeAmount = uint128(bound(_feeAmount, 1, type(uint128).max / feeTapper.perBlockReleaseRate() / BPS));

        Currency currency = _useNativeCurrency ? Currency.wrap(address(0)) : Currency.wrap(address(erc20Currency));
        _deal(address(feeTapper), _feeAmount, _useNativeCurrency);
        feeTapper.sync(currency);

        uint256 snapshotId = vm.snapshot();

        // Maximize number of releases by calling one per block
        uint128 totalReleased = 0;
        uint256 maxDust = 0;
        for (uint64 i = 0; i < BPS / feeTapper.perBlockReleaseRate(); i++) {
            vm.roll(block.number + 1);
            totalReleased += feeTapper.release(currency);
            maxDust++;
        }

        vm.revertTo(snapshotId);

        // Now test releasing all in one go after BPS / perBlockReleaseRate() blocks
        vm.roll(block.number + BPS / feeTapper.perBlockReleaseRate());
        uint256 endTotalReleased = feeTapper.release(currency);
        assertApproxEqAbs(endTotalReleased, totalReleased, maxDust, "total released should be the same");
    }
}
