// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDC - Mock USDC Token for Testing
 * @notice 6 decimal stablecoin mock
 */
contract MockUSDC is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000;
    uint8 public constant DECIMALS = 6;

    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, INITIAL_SUPPLY * 10 ** decimals());
    }

    /**
     * @notice Mint tokens for testing
     * @param to Address to mint to
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Get decimals
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
