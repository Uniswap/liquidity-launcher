// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Shared mainnet fork fixture for position recipient tests
abstract contract PositionRecipientTestBase is Test {
    // Constants
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant NATIVE = 0x0000000000000000000000000000000000000000;

    // Shared fork fixture for position recipient tests
    // Position created here: https://etherscan.io/tx/0x03dafd828c6b47362b1f53d7a692f8f52b8bc44b513f8c9caa9195e1061113a4
    // And the fork block is a few blocks after, allowing the position to have non zero fees
    uint256 internal constant FORK_BLOCK = 23936030;
    uint256 internal constant FORK_TOKEN_ID = 107192;
    uint256 internal constant FORK_CURRENCY0_FEES_AMOUNT = 709706242928;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("QUICKNODE_RPC_URL"));
    }

    // Transfer a v4 position from one owner to another
    function _yoinkPosition(uint256 _tokenId, address _newOwner) internal {
        address originalOwner = IERC721(POSITION_MANAGER).ownerOf(_tokenId);
        vm.prank(originalOwner);
        IERC721(POSITION_MANAGER).transferFrom(originalOwner, _newOwner, _tokenId);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(_tokenId), _newOwner);
    }

    // Deal a pool token from the pool manager to an address
    // (the pool manager custodies every v4 pool's reserves; vm.deal() doesn't work well for proxied tokens)
    function _dealTokenFromPoolManager(address _token, address _to, uint256 _amount) internal {
        vm.prank(POOL_MANAGER);
        bool success = IERC20(_token).transfer(_to, _amount);
        assertTrue(success);
    }

    function _dealUSDCFromPoolManager(address _to, uint256 _amount) internal {
        _dealTokenFromPoolManager(USDC, _to, _amount);
    }

    function _poolKey(uint256 _tokenId) internal view returns (PoolKey memory poolKey) {
        (poolKey,) = IPositionManager(POSITION_MANAGER).getPoolAndPositionInfo(_tokenId);
    }
}
