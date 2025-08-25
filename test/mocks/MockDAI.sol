// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockDAI - Mock DAI Token for Testing
 * @notice 18 decimal stablecoin mock
 */
contract MockDAI is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000;
    uint8 public constant DECIMALS = 18;

    constructor() ERC20("DAI Stablecoin", "DAI") {
        _mint(msg.sender, INITIAL_SUPPLY * 10 ** DECIMALS);
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
     * @notice Get decimals (18 for DAI)
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
