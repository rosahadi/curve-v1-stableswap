// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MockDAI} from "../test/mocks/MockDAI.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockUSDT} from "../test/mocks/MockUSDT.sol";
import {TokenFactory} from "../test/mocks/TokenFactory.sol";

/**
 * @title HelperConfig - Network Configuration Helper
 * @author Rosa Hadi
 * @notice Provides network-specific configurations for deployment
 * @dev Handles Anvil local testing, Sepolia testnet, and Mainnet configurations
 */
contract HelperConfig is Script {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error HelperConfig_MockDeploymentNotAllowed();
    error HelperConfig_TokensNotDeployed();
    error HelperConfig_CanOnlyFundWithMocks();

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct NetworkConfig {
        address dai;
        address usdc;
        address usdt;
        uint256 initialA;
        uint256 fee;
        uint256 adminFee;
        bool deployMocks; // Whether to deploy mock tokens
        string description; // Network description
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Chain IDs
    uint256 public constant ETH_MAINNET_CHAIN_ID = 1;
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant LOCAL_CHAIN_ID = 31337;

    // Default Curve parameters
    uint256 public constant DEFAULT_INITIAL_A = 2000; // A = 2000 (conservative)
    uint256 public constant DEFAULT_FEE = 4000000; // 0.04% trading fee
    uint256 public constant DEFAULT_ADMIN_FEE = 5000000000; // 50% of trading fees go to admin

    // Mainnet token addresses (real tokens)
    address public constant MAINNET_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant MAINNET_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    NetworkConfig public activeNetworkConfig;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        if (block.chainid == ETH_MAINNET_CHAIN_ID) {
            activeNetworkConfig = getMainnetEthConfig();
        } else if (block.chainid == ETH_SEPOLIA_CHAIN_ID) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    /*//////////////////////////////////////////////////////////////
                        CONFIGURATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get Mainnet configuration with real token addresses
     * @return Mainnet network configuration
     */
    function getMainnetEthConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory mainnetConfig = NetworkConfig({
            dai: MAINNET_DAI,
            usdc: MAINNET_USDC,
            usdt: MAINNET_USDT,
            initialA: DEFAULT_INITIAL_A,
            fee: DEFAULT_FEE,
            adminFee: DEFAULT_ADMIN_FEE,
            deployMocks: false,
            description: "Ethereum Mainnet"
        });

        return mainnetConfig;
    }

    /**
     * @notice Get Sepolia testnet configuration
     * @dev Returns empty addresses - will deploy mocks if needed
     * @return Sepolia network configuration
     */
    function getSepoliaEthConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory sepoliaConfig = NetworkConfig({
            dai: address(0), // Will be deployed as mock
            usdc: address(0), // Will be deployed as mock
            usdt: address(0), // Will be deployed as mock
            initialA: DEFAULT_INITIAL_A,
            fee: DEFAULT_FEE,
            adminFee: DEFAULT_ADMIN_FEE,
            deployMocks: true,
            description: "Sepolia Testnet"
        });

        return sepoliaConfig;
    }

    /**
     * @notice Get or create Anvil local configuration
     * @dev Deploys mock tokens if running on Anvil
     * @return Anvil network configuration
     */
    function getOrCreateAnvilEthConfig() public view returns (NetworkConfig memory) {
        if (activeNetworkConfig.dai != address(0)) {
            return activeNetworkConfig;
        }

        return NetworkConfig({
            dai: address(0), // Will be deployed as mock
            usdc: address(0), // Will be deployed as mock
            usdt: address(0), // Will be deployed as mock
            initialA: DEFAULT_INITIAL_A,
            fee: DEFAULT_FEE,
            adminFee: DEFAULT_ADMIN_FEE,
            deployMocks: true,
            description: "Anvil Local"
        });
    }

    /**
     * @notice Deploy mock tokens for testnets
     * @dev Should be called before pool deployment on Sepolia/Anvil
     * @return dai DAI token address
     * @return usdc USDC token address
     * @return usdt USDT token address
     */
    function deployMockTokens() public returns (address dai, address usdc, address usdt) {
        NetworkConfig memory config = activeNetworkConfig;
        if (!config.deployMocks) revert HelperConfig_MockDeploymentNotAllowed();

        console2.log("Deploying mock tokens for", config.description);

        // Deploy mock tokens
        MockDAI daiToken = new MockDAI();
        MockUSDC usdcToken = new MockUSDC();
        MockUSDT usdtToken = new MockUSDT();

        dai = address(daiToken);
        usdc = address(usdcToken);
        usdt = address(usdtToken);

        // Update active config
        activeNetworkConfig.dai = dai;
        activeNetworkConfig.usdc = usdc;
        activeNetworkConfig.usdt = usdt;

        console2.log("Mock tokens deployed:");
        console2.log("DAI:", dai);
        console2.log("USDC:", usdc);
        console2.log("USDT:", usdt);

        return (dai, usdc, usdt);
    }

    /**
     * @notice Get current active network configuration
     * @return Current network configuration
     */
    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        return activeNetworkConfig;
    }

    /**
     * @notice Get token addresses as array for pool deployment
     * @return Token addresses in the order [DAI, USDC, USDT]
     */
    function getTokenAddresses() public view returns (address[3] memory) {
        NetworkConfig memory config = getActiveNetworkConfig();
        if (config.dai == address(0)) revert HelperConfig_TokensNotDeployed();
        return [config.dai, config.usdc, config.usdt];
    }

    /**
     * @notice Get pool parameters for deployment
     * @return initialA Initial amplification coefficient
     * @return fee Trading fee
     * @return adminFee Admin fee percentage
     */
    function getPoolParameters() public view returns (uint256 initialA, uint256 fee, uint256 adminFee) {
        NetworkConfig memory config = getActiveNetworkConfig();
        return (config.initialA, config.fee, config.adminFee);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fund account with test tokens (Testnet only)
     * @param account Account to fund
     * @param amount Amount of each token to mint (in DAI units - 18 decimals)
     */
    function fundAccountWithTokens(address account, uint256 amount) public {
        NetworkConfig memory config = getActiveNetworkConfig();
        if (!config.deployMocks) revert HelperConfig_CanOnlyFundWithMocks();
        if (config.dai == address(0)) revert HelperConfig_TokensNotDeployed();

        // Mint tokens to the account
        MockDAI(config.dai).mint(account, amount);
        MockUSDC(config.usdc).mint(account, amount / 1e12); // Adjust for 6 decimals
        MockUSDT(config.usdt).mint(account, amount / 1e12); // Adjust for 6 decimals

        console2.log("Funded account:", account);
        console2.log("DAI balance:", MockDAI(config.dai).balanceOf(account));
        console2.log("USDC balance:", MockUSDC(config.usdc).balanceOf(account));
        console2.log("USDT balance:", MockUSDT(config.usdt).balanceOf(account));
    }

    /**
     * @notice Get network name for logging
     * @return Network name string
     */
    function getNetworkName() public view returns (string memory) {
        return activeNetworkConfig.description;
    }

    /**
     * @notice Check if current network should deploy mocks
     * @return True if should deploy mocks
     */
    function shouldDeployMocks() public view returns (bool) {
        return activeNetworkConfig.deployMocks;
    }

    /**
     * @notice Check if tokens are already deployed
     * @return True if tokens are deployed
     */
    function tokensDeployed() public view returns (bool) {
        NetworkConfig memory config = getActiveNetworkConfig();
        return config.dai != address(0) && config.usdc != address(0) && config.usdt != address(0);
    }
}
