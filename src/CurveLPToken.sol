// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CurveLPToken - Curve Liquidity Provider Token
 * @author Rosa Hadi
 * @notice ERC20 token representing shares in a Curve pool
 * @dev Only the pool contract can mint/burn tokens
 */
contract CurveLPToken is ERC20, Ownable {
    address public s_minter;

    event MinterSet(address indexed minter);

    /**
     * @notice Initialize the LP token
     * @param name Token name (e.g., "Curve.fi DAI/USDC/USDT")
     * @param symbol Token symbol (e.g., "3CRV")
     * @param _minter Address that can mint/burn (the pool contract)
     * @param initialOwner Initial owner of the contract
     */
    constructor(
        string memory name,
        string memory symbol,
        address _minter,
        address initialOwner
    ) ERC20(name, symbol) Ownable(initialOwner) {
        require(_minter != address(0), "Invalid minter");
        s_minter = _minter;
        emit MinterSet(s_minter);
    }

     /**
     * @notice Mint new LP tokens
     * @dev Only the designated minter (pool contract) can mint
     * @param _to Address to receive tokens
     * @param _value Amount to mint
     * @return success True if mint was successful
     */
    function mint(address _to, uint256 _value) external returns (bool success) {
        require(msg.sender == s_minter, "Only minter can mint");
        require(_to != address(0), "Cannot mint to zero address");

        _mint(_to, _value);
        return true;
    }

    /**
     * @notice Burn tokens from holder's balance
     * @dev Only the designated minter (pool contract) can burn
     * @param _from Address to burn tokens from
     * @param _value Amount to burn
     * @return success True if burn was successful
     */
    function burnFrom(address _from, uint256 _value) external returns (bool success) {
        require(msg.sender == s_minter, "Only minter can burn");
        require(_from != address(0), "Cannot burn from zero address");
        require(balanceOf(_from) >= _value, "Insufficient balance");

        _burn(_from, _value);
        return true;
    }

    /**
     * @notice Set new minter address
     * @dev Only owner can change minter
     * @param _minter New minter address
     */
    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "Invalid minter");
        s_minter = _minter;
        emit MinterSet(_minter);
    }
}
