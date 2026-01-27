// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

struct DeployParameters {
    IPositionManager positionManager;
    IPoolManager poolManager;
    bytes32 salt;
}

/// @title Parameters
contract Parameters {
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant DEFAULT_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Mainnet addresses: https://docs.uniswap.org/contracts/v4/deployments#ethereum-1
    IPositionManager public constant MAINNET_POSITION_MANAGER =
        IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPoolManager public constant MAINNET_POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    // Base addresses: https://docs.uniswap.org/contracts/v4/deployments#base-8453
    IPositionManager public constant BASE_POSITION_MANAGER =
        IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc);
    IPoolManager public constant BASE_POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    // Unichain addresses: https://docs.uniswap.org/contracts/v4/deployments#unichain-130
    IPositionManager public constant UNICHAIN_POSITION_MANAGER =
        IPositionManager(0x4529A01c7A0410167c5740C487A8DE60232617bf);
    IPoolManager public constant UNICHAIN_POOL_MANAGER = IPoolManager(0x1F98400000000000000000000000000000000004);

    // Sepolia addresses: https://docs.uniswap.org/contracts/v4/deployments#sepolia-11155111
    IPositionManager public constant SEPOLIA_POSITION_MANAGER =
        IPositionManager(0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4);
    IPoolManager public constant SEPOLIA_POOL_MANAGER = IPoolManager(0xE03A1074c86CFeDd5C142C4F04F1a1536e203543);

    // Base Sepolia addresses: https://docs.uniswap.org/contracts/v4/deployments#base-sepolia-84532
    IPositionManager public constant BASE_SEPOLIA_POSITION_MANAGER =
        IPositionManager(0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80);
    IPoolManager public constant BASE_SEPOLIA_POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);

    uint256 public constant MAINNET_CHAIN_ID = 1;
    uint256 public constant BASE_CHAIN_ID = 8453;
    uint256 public constant UNICHAIN_CHAIN_ID = 130;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    bytes32 public DEFAULT_SALT = 0x0000000000000000000000000000000000000000000000000000000000000000;

    /// @notice Thrown when parameters are not set for a given chainId
    error ParametersNotSetForChainId(uint256 chainId);

    mapping(uint256 chainId => DeployParameters) public parameters;

    constructor() {
        parameters[MAINNET_CHAIN_ID] = DeployParameters({
            positionManager: MAINNET_POSITION_MANAGER, poolManager: MAINNET_POOL_MANAGER, salt: DEFAULT_SALT
        });
        parameters[BASE_CHAIN_ID] = DeployParameters({
            positionManager: BASE_POSITION_MANAGER, poolManager: BASE_POOL_MANAGER, salt: DEFAULT_SALT
        });
        parameters[UNICHAIN_CHAIN_ID] = DeployParameters({
            positionManager: UNICHAIN_POSITION_MANAGER, poolManager: UNICHAIN_POOL_MANAGER, salt: DEFAULT_SALT
        });
        parameters[SEPOLIA_CHAIN_ID] = DeployParameters({
            positionManager: SEPOLIA_POSITION_MANAGER, poolManager: SEPOLIA_POOL_MANAGER, salt: DEFAULT_SALT
        });
        parameters[BASE_SEPOLIA_CHAIN_ID] = DeployParameters({
            positionManager: BASE_SEPOLIA_POSITION_MANAGER, poolManager: BASE_SEPOLIA_POOL_MANAGER, salt: DEFAULT_SALT
        });
    }

    function getParameters(uint256 chainId) public view returns (DeployParameters memory) {
        DeployParameters memory params = parameters[chainId];
        if (address(params.positionManager) == address(0) || address(params.poolManager) == address(0)) {
            revert ParametersNotSetForChainId(chainId);
        }
        return params;
    }
}
