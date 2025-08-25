// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockDAI} from "./MockDAI.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockUSDT} from "./MockUSDT.sol";

/**
 * @title TokenFactory - Factory for deploying mock tokens
 * @notice Helper contract for easy token deployment in tests
 */
contract TokenFactory {
    error TokenFactory_UnsupportedToken(string tokenType);

    event TokenDeployed(string tokenType, address tokenAddress);

    /**
     * @notice Deploy all three mock tokens
     * @return dai DAI token address
     * @return usdc USDC token address
     * @return usdt USDT token address
     */
    function deployAllTokens() external returns (address dai, address usdc, address usdt) {
        dai = address(new MockDAI());
        usdc = address(new MockUSDC());
        usdt = address(new MockUSDT());

        emit TokenDeployed("DAI", dai);
        emit TokenDeployed("USDC", usdc);
        emit TokenDeployed("USDT", usdt);

        return (dai, usdc, usdt);
    }

    /**
     * @notice Deploy individual token
     * @param tokenType Type of token ("DAI", "USDC", or "USDT")
     * @return token Token address
     */
    function deployToken(string memory tokenType) external returns (address token) {
        bytes32 typeHash = keccak256(abi.encodePacked(tokenType));

        if (typeHash == keccak256("DAI")) {
            token = address(new MockDAI());
        } else if (typeHash == keccak256("USDC")) {
            token = address(new MockUSDC());
        } else if (typeHash == keccak256("USDT")) {
            token = address(new MockUSDT());
        } else {
            revert TokenFactory_UnsupportedToken(tokenType);
        }

        emit TokenDeployed(tokenType, token);
        return token;
    }
}
