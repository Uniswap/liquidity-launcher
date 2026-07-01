// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

struct DeployParameters {
    IPositionManager positionManager;
    IPoolManager poolManager;
    bytes32 salt; // salt required to deploy LBPStrategy contracts to valid v4 hook addresses across chains
}

/// @title Parameters
contract Parameters {
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant DEFAULT_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 public constant DEFAULT_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG;

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

    // Arbitrum addresses: https://developers.uniswap.org/docs/protocols/v4/deployments#arbitrum-one-42161
    IPositionManager public constant ARBITRUM_POSITION_MANAGER =
        IPositionManager(0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869);
    IPoolManager public constant ARBITRUM_POOL_MANAGER = IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);

    // Avalanche addresses: https://developers.uniswap.org/docs/protocols/v4/deployments#avalanche-43114
    IPositionManager public constant AVALANCHE_POSITION_MANAGER =
        IPositionManager(0xB74b1F14d2754AcfcbBe1a221023a5cf50Ab8ACD);
    IPoolManager public constant AVALANCHE_POOL_MANAGER = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);

    // XLayer addresses: https://developers.uniswap.org/docs/protocols/v4/deployments#x-layer-196
    IPositionManager public constant XLAYER_POSITION_MANAGER =
        IPositionManager(0xcF1EAFC6928dC385A342E7C6491d371d2871458b);
    IPoolManager public constant XLAYER_POOL_MANAGER = IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);

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
    uint256 public constant ARBITRUM_CHAIN_ID = 42161;
    uint256 public constant AVALANCHE_CHAIN_ID = 43114;
    uint256 public constant XLAYER_CHAIN_ID = 196;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    /// @notice Thrown when parameters are not set for a given chainId
    error ParametersNotSetForChainId(uint256 chainId);

    mapping(uint256 chainId => DeployParameters) public parameters;

    constructor() {
        parameters[MAINNET_CHAIN_ID] = DeployParameters({
            positionManager: MAINNET_POSITION_MANAGER,
            poolManager: MAINNET_POOL_MANAGER,
            salt: 0x00000000000000000000000000000000000000000000000000000000000079e3
        });
        parameters[BASE_CHAIN_ID] = DeployParameters({
            positionManager: BASE_POSITION_MANAGER,
            poolManager: BASE_POOL_MANAGER,
            salt: 0x000000000000000000000000000000000000000000000000000000000000e380
        });
        parameters[UNICHAIN_CHAIN_ID] = DeployParameters({
            positionManager: UNICHAIN_POSITION_MANAGER,
            poolManager: UNICHAIN_POOL_MANAGER,
            salt: 0x000000000000000000000000000000000000000000000000000000000000848a
        });
        parameters[ARBITRUM_CHAIN_ID] = DeployParameters({
            positionManager: ARBITRUM_POSITION_MANAGER,
            poolManager: ARBITRUM_POOL_MANAGER,
            salt: 0x0000000000000000000000000000000000000000000000000000000000007740
        });
        parameters[AVALANCHE_CHAIN_ID] = DeployParameters({
            positionManager: AVALANCHE_POSITION_MANAGER,
            poolManager: AVALANCHE_POOL_MANAGER,
            salt: 0x0000000000000000000000000000000000000000000000000000000000003528
        });
        parameters[XLAYER_CHAIN_ID] = DeployParameters({
            positionManager: XLAYER_POSITION_MANAGER,
            poolManager: XLAYER_POOL_MANAGER,
            salt: 0x00000000000000000000000000000000000000000000000000000000000022f7
        });
        parameters[SEPOLIA_CHAIN_ID] = DeployParameters({
            positionManager: SEPOLIA_POSITION_MANAGER,
            poolManager: SEPOLIA_POOL_MANAGER,
            salt: 0x00000000000000000000000000000000000000000000000000000000000068fc
        });
        parameters[BASE_SEPOLIA_CHAIN_ID] = DeployParameters({
            positionManager: BASE_SEPOLIA_POSITION_MANAGER,
            poolManager: BASE_SEPOLIA_POOL_MANAGER,
            salt: 0x000000000000000000000000000000000000000000000000000000000000179e
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
