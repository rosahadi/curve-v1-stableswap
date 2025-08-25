// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockUSDT - Mock USDT Token for Testing
 * @notice 6 decimal stablecoin mock with transfer fees
 * @dev Simulates USDT's fee-on-transfer behavior
 */
contract MockUSDT is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000;
    uint8 public constant DECIMALS_USDT = 6;
    uint256 public constant MAX_TRANSFER_FEE = 1000;

    /// @notice Fee rate (in basis points, 10000 = 100%)
    uint256 public transferFee = 0;
    /// @notice Address that receives transfer fees
    address public feeRecipient;

    event TransferFeeUpdated(uint256 newFee);
    event FeeRecipientUpdated(address newRecipient);

    constructor() ERC20("Tether USD", "USDT") {
        _mint(msg.sender, INITIAL_SUPPLY * 10 ** DECIMALS_USDT);
        feeRecipient = msg.sender;
    }

    /**
     * @notice Override transfer to implement fees
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && transferFee > 0) {
            uint256 fee = (value * transferFee) / 10000;
            if (fee > 0) {
                super._update(from, feeRecipient, fee);
                value -= fee;
            }
        }
        super._update(from, to, value);
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
     * @notice Set transfer fee (for testing fee-on-transfer behavior)
     * @param _fee Fee in basis points
     */
    function setTransferFee(uint256 _fee) external {
        require(_fee <= MAX_TRANSFER_FEE, "Fee too high"); // Max 10%
        transferFee = _fee;
        emit TransferFeeUpdated(_fee);
    }

    /**
     * @notice Set fee recipient
     * @param _recipient New fee recipient
     */
    function setFeeRecipient(address _recipient) external {
        require(_recipient != address(0), "Invalid recipient");
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(_recipient);
    }

    /**
     * @notice Get decimals
     */
    function decimals() public pure override returns (uint8) {
        return DECIMALS_USDT;
    }
}
