// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ICurveToken - Interface for Curve LP Token
 * @notice Interface for the LP (Liquidity Provider) token used in Curve pools
 * @dev This token represents shares in the liquidity pool and extends IERC20
 */
interface ICurveToken is IERC20 {
    event MinterSet(address indexed minter);

    /**
     * @notice Mint new LP tokens
     * @dev Only the pool contract should be able to mint
     * @param _to Address to receive the tokens
     * @param _value Amount of tokens to mint
     * @return True if successful
     */
    function mint(address _to, uint256 _value) external returns (bool);

    /**
     * @notice Burn LP tokens from holder
     * @dev Only the pool contract should be able to burn
     * @param _from Address to burn tokens from
     * @param _value Amount of tokens to burn
     * @return True if successful
     */
    function burnFrom(address _from, uint256 _value) external returns (bool);

    /**
     * @notice Get the current minter address
     * @return Address of the current minter
     */
    function s_minter() external view returns (address);

    /**
     * @notice Set new minter address
     * @dev Only owner can change minter
     * @param _minter New minter address
     */
    function setMinter(address _minter) external;
}
