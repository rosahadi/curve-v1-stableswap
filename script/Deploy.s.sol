// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {CurveV1Pool, IERC20} from "../src/CurveV1Pool.sol";
import {CurveLPToken} from "../src/CurveLPToken.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/**
 * @title DeployCurvePool - Curve Pool Deployment Script
 * @author Rosa Hadi
 * @notice Deploys a complete Curve V1 pool setup with LP token
 * @dev Handles Anvil, Sepolia testnet, and Mainnet deployments
 */
contract DeployCurvePool is Script {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolDeployed(
        address indexed pool,
        address indexed lpToken,
        address[3] tokens,
        uint256 initialA,
        uint256 fee,
        uint256 adminFee,
        string network
    );

    /*//////////////////////////////////////////////////////////////
                              MAIN DEPLOY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Main deployment function
     * @return pool The deployed pool contract
     * @return lpToken The deployed LP token contract
     * @return tokens Array of underlying token addresses
     */
    function run() external returns (CurveV1Pool pool, CurveLPToken lpToken, address[3] memory tokens) {
        // Get network configuration
        HelperConfig helperConfig = new HelperConfig();

        // Log deployment info
        console2.log("~~~ Deploying Curve V1 Pool ~~~");
        console2.log("Network:", helperConfig.getNetworkName());
        console2.log("Chain ID:", block.chainid);

        // Get deployer private key
        uint256 deployerPrivateKey = getDeployerPrivateKey(helperConfig.shouldDeployMocks());
        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer address:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy tokens if needed (for testnets)
        if (helperConfig.shouldDeployMocks() && !helperConfig.tokensDeployed()) {
            console2.log("Deploying mock tokens...");
            helperConfig.deployMockTokens();
        }

        // Get token addresses and parameters
        tokens = helperConfig.getTokenAddresses();
        (uint256 initialA, uint256 fee, uint256 adminFee) = helperConfig.getPoolParameters();

        console2.log("Token addresses:");
        console2.log("  DAI:", tokens[0]);
        console2.log("  USDC:", tokens[1]);
        console2.log("  USDT:", tokens[2]);
        console2.log("Pool parameters:");
        console2.log("  Initial A:", initialA);
        console2.log("  Fee:", fee);
        console2.log("  Admin Fee:", adminFee);

        // Deploy LP Token first
        lpToken = new CurveLPToken(
            "Curve.fi DAI/USDC/USDT", // name
            "3CRV", // symbol
            address(0), // minter (will be set to pool address)
            deployer // initial owner
        );

        console2.log("LP Token deployed at:", address(lpToken));

        // Deploy Pool
        pool = new CurveV1Pool(
            deployer, // owner
            tokens, // coin addresses
            address(lpToken), // pool token
            initialA, // amplification coefficient
            fee, // trading fee
            adminFee // admin fee
        );

        console2.log("Pool deployed at:", address(pool));

        // Set pool as the minter for LP token
        lpToken.setMinter(address(pool));
        console2.log("Pool set as LP token minter");

        vm.stopBroadcast();

        // Emit deployment event
        emit PoolDeployed(
            address(pool), address(lpToken), tokens, initialA, fee, adminFee, helperConfig.getNetworkName()
        );

        // Log final deployment info
        logDeploymentSummary(pool, lpToken, tokens);

        return (pool, lpToken, tokens);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get deployer private key based on network
     * @param isTestnet Whether this is a testnet deployment
     * @return Private key for deployment
     */
    function getDeployerPrivateKey(bool isTestnet) internal view returns (uint256) {
        if (isTestnet || block.chainid == 31337) {
            // Use environment variable or default Anvil key
            try vm.envUint("PRIVATE_KEY") returns (uint256 key) {
                return key;
            } catch {
                // Default Anvil key if no environment variable
                return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
            }
        } else {
            // Mainnet - require environment variable
            return vm.envUint("PRIVATE_KEY");
        }
    }

    /**
     * @notice Log deployment summary
     */
    function logDeploymentSummary(CurveV1Pool pool, CurveLPToken lpToken, address[3] memory tokens) internal view {
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Pool Address: %s", address(pool));
        console2.log("LP Token Address: %s", address(lpToken));
        console2.log("LP Token Name: %s", lpToken.name());
        console2.log("LP Token Symbol: %s", lpToken.symbol());
        console2.log("");
        console2.log("Token Addresses:");
        console2.log("  DAI:  %s", tokens[0]);
        console2.log("  USDC: %s", tokens[1]);
        console2.log("  USDT: %s", tokens[2]);
        console2.log("");
        console2.log("Pool Parameters:");
        console2.log("  Amplification Coefficient: %d", pool.A());
        console2.log("  Trading Fee: %d", pool.fee());
        console2.log("  Admin Fee: %d", pool.admin_fee());
        console2.log("  Owner: %s", pool.owner());
        console2.log("");
    }

    /**
     * @notice Setup initial liquidity for testing (Testnet only)
     * @param poolAddress Pool address
     * @param lpTokenAddress LP token address
     * @param liquidityAmount Amount of liquidity to add (in DAI units)
     */
    function setupInitialLiquidity(address poolAddress, address lpTokenAddress, uint256 liquidityAmount) external {
        HelperConfig helperConfig = new HelperConfig();
        require(helperConfig.shouldDeployMocks(), "Only for testnets");

        address[3] memory tokens = helperConfig.getTokenAddresses();
        uint256 deployerPrivateKey = getDeployerPrivateKey(true);
        address deployer = vm.addr(deployerPrivateKey);

        // Fund deployer with tokens
        helperConfig.fundAccountWithTokens(deployer, liquidityAmount * 2); // Extra buffer

        vm.startBroadcast(deployerPrivateKey);

        // Approve pool to spend tokens
        IERC20(tokens[0]).approve(poolAddress, type(uint256).max); // DAI
        IERC20(tokens[1]).approve(poolAddress, type(uint256).max); // USDC
        IERC20(tokens[2]).approve(poolAddress, type(uint256).max); // USDT

        // Add initial liquidity - balanced amounts
        uint256[3] memory amounts = [
            liquidityAmount, // DAI (18 decimals)
            liquidityAmount / 1e12, // USDC (6 decimals)
            liquidityAmount / 1e12 // USDT (6 decimals)
        ];

        CurveV1Pool(poolAddress).add_liquidity(amounts, 0);

        vm.stopBroadcast();

        uint256 lpBalance = IERC20(lpTokenAddress).balanceOf(deployer);
        console2.log("Initial liquidity added:");
        console2.log("  DAI: %d", amounts[0]);
        console2.log("  USDC: %d", amounts[1]);
        console2.log("  USDT: %d", amounts[2]);
        console2.log("  LP tokens received: %d", lpBalance);
    }

    /**
     * @notice Deploy and setup pool with initial liquidity (one command)
     * @param liquidityAmount Amount of initial liquidity to add
     */
    function deployAndSetup(uint256 liquidityAmount) external {
        // Deploy pool
        (CurveV1Pool pool, CurveLPToken lpToken,) = this.run();

        // Add initial liquidity if testnet
        HelperConfig helperConfig = new HelperConfig();
        if (helperConfig.shouldDeployMocks()) {
            this.setupInitialLiquidity(address(pool), address(lpToken), liquidityAmount);
        }
    }

    /**
     * @notice Print pool status for debugging
     * @param poolAddress Pool address to inspect
     */
    function printPoolStatus(address poolAddress) external view {
        CurveV1Pool curvePool = CurveV1Pool(poolAddress);

        console2.log("~~~ Pool Status ~~~");
        console2.log("Pool Address: %s", poolAddress);
        console2.log("Owner: %s", curvePool.owner());
        console2.log("A parameter: %d", curvePool.A());
        console2.log("Fee: %d", curvePool.fee());
        console2.log("Admin Fee: %d", curvePool.admin_fee());
        console2.log("Is Killed: %s", curvePool.is_killed() ? "true" : "false");

        console2.log("Token Balances:");
        for (uint256 i = 0; i < 3; i++) {
            console2.log("  Token %d balance: %d", i, curvePool.balances(i));
        }

        uint256 totalSupply = curvePool.token().totalSupply();
        if (totalSupply > 0) {
            console2.log("LP Token Supply: %d", totalSupply);
            console2.log("Virtual Price: %d", curvePool.get_virtual_price());
        } else {
            console2.log("No liquidity in pool");
        }
        console2.log("");
    }
}
