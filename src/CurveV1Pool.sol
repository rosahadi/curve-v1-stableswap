// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICurveToken} from "./interfaces/ICurveToken.sol";

/**
 * @title CurveV1Pool - StableSwap AMM Implementation
 * @author Rosa Hadi
 * @notice A Curve V1 style stableswap pool for DAI/USDC/USDT with amplification coefficient
 * @dev This contract implements the Curve StableSwap invariant using Newton's method for convergence
 *
 * CURVE'S STABLESWAP INVARIANT:
 * The core of Curve is the StableSwap invariant equation:
 * A * n^n * Σ(x_i) + D = A * D * n^n + D^(n+1) / (n^n * Π(x_i))
 *
 * Where:
 * - A = amplification parameter (controls curve shape)
 * - n = number of coins (3 for DAI/USDC/USDT)
 * - x_i = normalized balance of coin i (18 decimal precision)
 * - D = invariant (represents total pool value)
 * - Σ(x_i) = sum of all balances
 * - Π(x_i) = product of all balances
 *
 * NEWTON'S METHOD FOR CONVERGENCE:
 * We use Newton's method to solve for D and exchange amounts:
 *
 * For calculating D (invariant):
 * D_{new} = (A*n^n*S + D_P*n) * D / ((A*n^n - 1)*D + (n+1)*D_P)
 * where:
 * - S = Σ(x_i) (sum of balances)
 * - D_P = D^(n+1) / (n^n * Π(x_i))
 *
 * For calculating exchange amounts (get_y):
 * We solve the invariant equation for the output amount y given input x
 * using iterative Newton's method until |y_new - y_old| ≤ 1
 *
 * PRECISION HANDLING:
 * - All internal calculations use 18-decimal precision
 * - DAI: 18 decimals → multiplier = 1
 * - USDC: 6 decimals → multiplier = 10^12
 * - USDT: 6 decimals → multiplier = 10^12
 * - RATES[i] = precision_multiplier * rate (normalized to 1e18)
 *
 * AMPLIFICATION PARAMETER (A):
 * Controls the shape of the bonding curve:
 * - Higher A → flatter curve → lower slippage for balanced trades
 * - Lower A → more curved → behaves more like constant product (x*y=k)
 * - Typical values: 100-10,000
 * - A=2000: Conservative choice for stablecoin pools
 * - Can be ramped up/down over time with safety constraints
 *
 * FEE STRUCTURE:
 * - Base fee: Applied to all trades (e.g., 0.04%)
 * - Dynamic fee for liquidity operations: fee * n / (4 * (n-1))
 * - Admin fee: Percentage of trading fees (e.g., 50%)
 * - Fees discourage imbalanced operations that deviate from 1:1 peg
 *
 * VIRTUAL PRICE:
 * - Virtual price = D * PRECISION / total_LP_supply
 * - Only increases over time (due to accumulated fees)
 * - Measures pool's appreciation and fee accumulation
 * - Used to track pool performance vs initial deposits
 *
 * SECURITY CONSIDERATIONS:
 * - Reentrancy protection on all external functions
 * - A parameter ramping limits to prevent manipulation
 * - Admin timelock on parameter changes (3 days)
 * - Emergency kill switch for extreme scenarios
 * - Precision handling to avoid rounding errors
 *
 * GAS OPTIMIZATION:
 * - Newton's method iterations limited to 255 for safety
 * - Batch balance updates to minimize storage writes
 * - Efficient invariant calculations with minimal precision loss
 */
contract CurveV1Pool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error CurveV1Pool_InvalidIndex(uint256 index);
    error CurveV1Pool_InvalidCoinAddress();
    error CurveV1Pool_InvalidPoolToken();
    error CurveV1Pool_InvalidAParameter();
    error CurveV1Pool_FeeTooHigh();
    error CurveV1Pool_AdminFeeTooHigh();
    error CurveV1Pool_PoolIsKilled();
    error CurveV1Pool_InitialDepositRequiresAllCoins();
    error CurveV1Pool_D1MustBeGreaterThanD0();
    error CurveV1Pool_SlippageTooHigh();
    error CurveV1Pool_SameCoin();
    error CurveV1Pool_InvalidTokenIndex();
    error CurveV1Pool_InsufficientOutputAmount();
    error CurveV1Pool_OnlyOwner();
    error CurveV1Pool_TooFrequent();
    error CurveV1Pool_InsufficientTime();
    error CurveV1Pool_AChangeTooLarge();
    error CurveV1Pool_ActiveAction();
    error CurveV1Pool_TooEarly();
    error CurveV1Pool_NoActiveAction();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant N_COINS = 3; // Number of coins in the pool (DAI, USDC, USDT)
    uint256 public constant FEE_DENOMINATOR = 10 ** 10; // Denominator for fee calculations
    uint256 public constant LENDING_PRECISION = 10 ** 18; // Base precision
    uint256 public constant PRECISION = 10 ** 18; // Calculation precision

    uint256 private constant DAI_MUL = 1; // 18 decimals → no change
    uint256 private constant USDC_MUL = 1e12; // 6 → 18 decimals
    uint256 private constant USDT_MUL = 1e12;

    // Fee constants
    uint256 public constant MAX_ADMIN_FEE = 10 * 10 ** 9; // 10%
    uint256 public constant MAX_FEE = 5 * 10 ** 9; // 0.5%
    uint256 public constant MAX_A = 10 ** 6; // Maximum amplification coefficient
    uint256 public constant MAX_A_CHANGE = 10; // Maximum A change factor

    // Time constants
    uint256 public constant ADMIN_ACTIONS_DELAY = 3 * 86400; // 3 days
    uint256 public constant MIN_RAMP_TIME = 86400; // 1 day

    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/
    // Token addresses for the 3-coin pool
    address[N_COINS] public coins;

    // Current balances of each token in the pool
    uint256[N_COINS] public balances;

    // Fee structure
    uint256 public fee; // Trading fee (e.g., 0.04% = 4 * 10^6)
    uint256 public admin_fee; // Admin fee percentage of trading fees

    // Pool governance
    address public owner;

    // LP token contract
    ICurveToken public token;

    // Amplification coefficient ramping
    uint256 public initial_A;
    uint256 public future_A;
    uint256 public initial_A_time;
    uint256 public future_A_time;

    // Admin actions with time delays
    uint256 public admin_actions_deadline;
    uint256 public future_fee;
    uint256 public future_admin_fee;

    // Emergency controls
    bool public is_killed;

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenExchange(
        address indexed buyer, int128 sold_id, uint256 tokens_sold, int128 bought_id, uint256 tokens_bought
    );

    event AddLiquidity(
        address indexed provider,
        uint256[N_COINS] token_amounts,
        uint256[N_COINS] fees,
        uint256 invariant,
        uint256 token_supply
    );

    event RemoveLiquidity(
        address indexed provider, uint256[N_COINS] token_amounts, uint256[N_COINS] fees, uint256 token_supply
    );

    event RemoveLiquidityOne(address indexed provider, uint256 token_amount, uint256 coin_amount);

    event RemoveLiquidityImbalance(
        address indexed provider,
        uint256[N_COINS] token_amounts,
        uint256[N_COINS] fees,
        uint256 invariant,
        uint256 token_supply
    );

    event RampA(uint256 old_A, uint256 new_A, uint256 initial_time, uint256 future_time);

    event StopRampA(uint256 A, uint256 t);

    event CommitNewFee(uint256 deadline, uint256 fee, uint256 admin_fee);
    event NewFee(uint256 fee, uint256 admin_fee);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the Curve pool
     * @param _owner Contract owner address
     * @param _coins Array of token addresses [DAI, USDC, USDT]
     * @param _pool_token LP token contract address
     * @param _A Initial amplification coefficient (multiplied by n*(n-1) where n=3)
     * @param _fee Trading fee in basis points (4000000 = 0.04%)
     * @param _admin_fee Percentage of trading fees that go to admin
     */
    constructor(
        address _owner,
        address[N_COINS] memory _coins,
        address _pool_token,
        uint256 _A,
        uint256 _fee,
        uint256 _admin_fee
    ) {
        for (uint256 i = 0; i < N_COINS; i++) {
            if (_coins[i] == address(0)) revert CurveV1Pool_InvalidCoinAddress();
        }
        if (_pool_token == address(0)) revert CurveV1Pool_InvalidPoolToken();
        if (_A <= 0 || _A >= MAX_A) revert CurveV1Pool_InvalidAParameter();
        if (_fee > MAX_FEE) revert CurveV1Pool_FeeTooHigh();
        if (_admin_fee > MAX_ADMIN_FEE) revert CurveV1Pool_AdminFeeTooHigh();

        coins = _coins;
        initial_A = _A;
        future_A = _A;
        fee = _fee;
        admin_fee = _admin_fee;
        owner = _owner;
        token = ICurveToken(_pool_token);
    }

    /*//////////////////////////////////////////////////////////////
                        AMPLIFICATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current amplification coefficient with ramping
     * @dev Linear ramping of the amplification coefficient A over time:
     *      - Smoothly transitions from initial_A to future_A between initial_A_time and future_A_time
     *      - Uses linear interpolation: A_current = A0 + (A1 - A0) * (t - t0) / (t1 - t0)
     *      - If ramp has finished (block.timestamp >= future_A_time), returns future_A
     * @return Current effective A value
     */
    function _A() internal view returns (uint256) {
        uint256 t1 = future_A_time;
        uint256 A1 = future_A;

        if (block.timestamp < t1) {
            uint256 A0 = initial_A;
            uint256 t0 = initial_A_time;

            if (A1 > A0) {
                // Ramping UP: future_A > initial_A
                // Increase A proportionally with elapsed time
                return A0 + ((A1 - A0) * (block.timestamp - t0)) / (t1 - t0);
            } else {
                // Ramping DOWN: future_A < initial_A
                // Decrease A proportionally with elapsed time
                return A0 - ((A0 - A1) * (block.timestamp - t0)) / (t1 - t0);
            }
        } else {
            return A1;
        }
    }

    /**
     * @notice External view of current A parameter
     */
    function A() external view returns (uint256) {
        return _A();
    }

    /*//////////////////////////////////////////////////////////////
                            PRICE CALCULATIONS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Get normalized balances (xp) for current pool state
     * @dev Converts all token balances to 18 decimal precision for calculations
     * @return result Array of normalized balances
     */
    function _xp() internal view returns (uint256[N_COINS] memory result) {
        result[0] = balances[0] * DAI_MUL; // DAI already 18 decimals
        result[1] = balances[1] * USDC_MUL; // USDC 6 → 18
        result[2] = balances[2] * USDT_MUL; // USDT 6 → 18
    }

    /**
     * @notice Get normalized balances for given balance array
     * @param _balances Array of token balances
     * @return result Array of normalized balances
     */
    function _xp_mem(uint256[N_COINS] memory _balances) internal pure returns (uint256[N_COINS] memory result) {
        result[0] = _balances[0] * DAI_MUL;
        result[1] = _balances[1] * USDC_MUL;
        result[2] = _balances[2] * USDT_MUL;
    }
}
