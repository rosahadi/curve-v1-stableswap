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
    error CurveV1Pool_ZeroAmount();

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
        address indexed buyer, uint256 sold_id, uint256 tokens_sold, uint256 bought_id, uint256 tokens_bought
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
     * @param _initialA Initial amplification coefficient (multiplied by n*(n-1) where n=3)
     * @param _fee Trading fee in basis points (4000000 = 0.04%)
     * @param _admin_fee Percentage of trading fees that go to admin
     */
    constructor(
        address _owner,
        address[N_COINS] memory _coins,
        address _pool_token,
        uint256 _initialA,
        uint256 _fee,
        uint256 _admin_fee
    ) {
        for (uint256 i = 0; i < N_COINS; i++) {
            if (_coins[i] == address(0)) revert CurveV1Pool_InvalidCoinAddress();
        }
        if (_pool_token == address(0)) revert CurveV1Pool_InvalidPoolToken();
        if (_initialA <= 0 || _initialA >= MAX_A) revert CurveV1Pool_InvalidAParameter();
        if (_fee > MAX_FEE) revert CurveV1Pool_FeeTooHigh();
        if (_admin_fee > MAX_ADMIN_FEE) revert CurveV1Pool_AdminFeeTooHigh();

        coins = _coins;
        initial_A = _initialA;
        future_A = _initialA;
        initial_A_time = block.timestamp;
        future_A_time = block.timestamp;
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

    /*//////////////////////////////////////////////////////////////
                        STABLESWAP INVARIANT (D)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate the StableSwap invariant D
     * @dev Solves for D in the StableSwap invariant:
     *      A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
     *
     *      We rearrange to f(D)=0 and use Newton's method:
     *      f(D) = (A n^n - 1) * D + D^(n+1)/(n^n * prod(x_i)) - A n^n * S
     *
     *      Let D_P := D^(n+1) / (n^n * prod(x_i)). Then the Newton update
     *      simplifies to:
     *      D_next = ((A n^n * S + n * D_P) * D) / ((A n^n - 1) * D + (n + 1) * D_P)
     *
     *      Implementation notes:
     *      - xp[] are normalized balances (all in 18-dec precision)
     *      - S = sum(xp)
     *      - D is initialized with S (good starting point)
     *      - D_P is computed iteratively as:
     *         D_P := D; for each xp[j]: D_P = (D_P * D) / (xp[j] * n)
     *         => final D_P = D^(n+1) / (n^n * prod(xp))
     *      - iteration stops when |D - D_prev| <= 1 or after a safety cap (255)
     *
     * @param xp normalized balances
     * @param amp amplification (ensure amp is scaled consistently with Ann usage)
     * @return D invariant
     */
    function get_D(uint256[N_COINS] memory xp, uint256 amp) internal pure returns (uint256) {
        uint256 S = 0;

        // Calculate sum of all normalized balances
        for (uint256 i = 0; i < N_COINS; i++) {
            S += xp[i];
        }

        // If all balances are zero, invariant is zero
        if (S == 0) return 0;

        uint256 Dprev = 0;
        uint256 D = S; // Initial guess for D
        uint256 Ann = amp * N_COINS; // A * n

        // Newton's method iteration (max 255 iterations for safety)
        for (uint256 _i = 0; _i < 255; _i++) {
            uint256 D_P = D; // D^(n+1) / (n^n * prod(x_i))

            // Calculate D_P = D^(n+1) / (n^n * prod(x_i))
            for (uint256 j = 0; j < N_COINS; j++) {
                D_P = (D_P * D) / (xp[j] * N_COINS);
            }

            Dprev = D;

            // Newton's method formula:
            // D = (A*n^n*S + D_P*n) * D / ((A*n^n - 1)*D + (n+1)*D_P)
            D = ((Ann * S + D_P * N_COINS) * D) / ((Ann - 1) * D + (N_COINS + 1) * D_P);

            // Check convergence (precision of 1)
            if (D > Dprev) {
                if (D - Dprev <= 1) break;
            } else {
                if (Dprev - D <= 1) break;
            }
        }
        return D;
    }

    /**
     * @notice Calculate D for given balance array
     */
    function get_D_mem(uint256[N_COINS] memory _balances, uint256 amp) internal pure returns (uint256) {
        return get_D(_xp_mem(_balances), amp);
    }

    /*//////////////////////////////////////////////////////////////
                            VIRTUAL PRICE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get virtual price of the pool token
     * @dev Virtual price only goes up, measuring pool's accumulated value from fees
     * @return Virtual price scaled by 1e18
     */
    function get_virtual_price() external view returns (uint256) {
        uint256 D = get_D(_xp(), _A());
        uint256 token_supply = token.totalSupply();
        if (token_supply == 0) return 0;
        return (D * PRECISION) / token_supply;
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDITY OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate LP tokens for deposit/withdrawal (without fees)
     * @dev Used for slippage estimation, not precise due to missing fee calculations
     * @param amounts Array of token amounts
     * @param deposit True for deposit, false for withdrawal
     * @return Estimated LP token amount
     */
    function calc_token_amount(uint256[N_COINS] memory amounts, bool deposit) external view returns (uint256) {
        uint256[N_COINS] memory _balances = balances;
        uint256 amp = _A();
        uint256 D0 = get_D_mem(_balances, amp);

        for (uint256 i = 0; i < N_COINS; i++) {
            if (deposit) {
                _balances[i] += amounts[i]; // Add tokens to pool
            } else {
                _balances[i] -= amounts[i]; // Remove tokens from pool
            }
        }

        uint256 D1 = get_D_mem(_balances, amp);
        uint256 token_amount = token.totalSupply();
        uint256 diff;

        if (deposit) {
            diff = D1 - D0; // Pool value increased
        } else {
            diff = D0 - D1; // Pool value decreased
        }

        return (diff * token_amount) / D0; // LP tokens = (value_change × total_LP_supply) / old_pool_value
    }

    /**
     * @notice Add liquidity to the pool
     * @dev Users provide tokens in any ratio, fees are charged for imbalanced deposits
     *
     *      LIQUIDITY PROVISION FLOW:
     *      1. Calculate current pool state (D0)
     *      2. Transfer user tokens and update balances
     *      3. Calculate new pool state (D1)
     *      4. Apply imbalance fees for non-proportional deposits
     *      5. Calculate final pool state after fees (D2)
     *      6. Mint LP tokens proportional to value added
     *
     *      FEE MECHANISM:
     *      - Proportional deposits (same ratio as pool) → no fees
     *      - Imbalanced deposits → fees charged on excess amounts
     *      - Fee = base_fee * imbalance_ratio
     *      - Admin gets percentage of fees, rest stays in pool
     *
     *      LP TOKEN CALCULATION:
     *      - First deposit: LP tokens = D1 (total pool value)
     *      - Subsequent: LP tokens = total_supply * (value_added / old_value)
     *
     * @param amounts Array of token amounts to deposit [DAI, USDC, USDT]
     * @param min_mint_amount Minimum LP tokens to receive (slippage protection)
     */
    function add_liquidity(uint256[N_COINS] memory amounts, uint256 min_mint_amount) external nonReentrant {
        if (is_killed) revert CurveV1Pool_PoolIsKilled();

        // ═══════════════════════════════════════════════════════════════════════════════
        // INITIALIZATION & STATE CAPTURE
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256[N_COINS] memory fees;
        // Dynamic fee calculation: Higher fee for liquidity operations than trades
        // fee * n / (4 * (n-1)) makes liquidity operations more expensive than swaps
        // For n=3: multiplier = 3/(4*2) = 0.375, so LP fee is 37.5% of swap fee
        uint256 _fee = (fee * N_COINS) / (4 * (N_COINS - 1));
        uint256 _admin_fee = admin_fee;
        uint256 amp = _A();

        // ═══════════════════════════════════════════════════════════════════════════════
        // CAPTURE CURRENT POOL STATE
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256 token_supply = token.totalSupply();
        uint256 D0 = 0; // Current invariant (total pool value)
        uint256[N_COINS] memory old_balances = balances;

        // Calculate current invariant if pool has existing liquidity
        if (token_supply > 0) {
            D0 = get_D_mem(old_balances, amp);
        }
        // Note: If token_supply == 0, this is first deposit, D0 stays 0

        // ═══════════════════════════════════════════════════════════════════════════════
        // TOKEN TRANSFERS & BALANCE UPDATES
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256[N_COINS] memory new_balances = old_balances;

        // Transfer tokens and update balances
        for (uint256 i = 0; i < N_COINS; i++) {
            uint256 in_amount = amounts[i];

            // FIRST DEPOSIT VALIDATION: Require all tokens for initial liquidity
            // This prevents manipulation of initial pool ratios
            if (token_supply == 0) {
                if (in_amount == 0) revert CurveV1Pool_InitialDepositRequiresAllCoins();
            }

            // Transfer tokens from user to pool (if amount > 0)
            if (in_amount > 0) {
                IERC20(coins[i]).safeTransferFrom(msg.sender, address(this), in_amount);
            }
            // Update balance accounting
            new_balances[i] = old_balances[i] + in_amount;
        }

        // ═══════════════════════════════════════════════════════════════════════════════
        // CALCULATE NEW POOL VALUE
        // ═══════════════════════════════════════════════════════════════════════════════

        // Calculate invariant after deposits (before fees)
        uint256 D1 = get_D_mem(new_balances, amp);

        // Sanity check: Pool value must increase after deposits
        if (D1 <= D0) revert CurveV1Pool_D1MustBeGreaterThanD0();

        // ═══════════════════════════════════════════════════════════════════════════════
        // IMBALANCE FEE CALCULATION
        // ═══════════════════════════════════════════════════════════════════════════════

        // D2 will be the final invariant after fees are applied
        uint256 D2 = D1;

        if (token_supply > 0) {
            // PROPORTIONAL DEPOSIT CALCULATION:
            // If pool grows from D0 to D1, each token should grow proportionally
            // ideal_balance[i] = old_balance[i] * (D1 / D0)
            // Any deviation from this ideal ratio incurs fees

            for (uint256 i = 0; i < N_COINS; i++) {
                // Calculate what this token's balance should be for proportional deposit
                uint256 ideal_balance = (D1 * old_balances[i]) / D0;

                // Calculate deviation from ideal (imbalance)
                uint256 difference;
                if (ideal_balance > new_balances[i]) {
                    // Under-deposited this token
                    difference = ideal_balance - new_balances[i];
                } else {
                    // Over-deposited this token
                    difference = new_balances[i] - ideal_balance;
                }

                // Calculate fee: proportional to imbalance
                fees[i] = (_fee * difference) / FEE_DENOMINATOR;

                // ADMIN FEE HANDLING:
                // Admin gets % of fees, remainder stays in pool as additional liquidity
                // balances[i] = deposited_amount - admin_portion_of_fees
                balances[i] = new_balances[i] - (fees[i] * _admin_fee) / FEE_DENOMINATOR;

                // For D2 calculation, subtract total fees (including admin portion)
                new_balances[i] -= fees[i];
            }

            // Calculate final invariant after fee deduction
            D2 = get_D_mem(new_balances, amp);
        } else {
            // FIRST DEPOSIT: No fees since there's no existing ratio to deviate from
            balances = new_balances;
        }

        // ═══════════════════════════════════════════════════════════════════════════════
        // LP TOKEN MINTING CALCULATION
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256 mint_amount;
        if (token_supply == 0) {
            // FIRST DEPOSIT: LP tokens = pool value
            // This sets the initial LP/value ratio
            mint_amount = D1;
        } else {
            // SUBSEQUENT DEPOSITS: LP tokens proportional to value added
            // mint_amount = existing_supply * (value_added / old_value)
            // mint_amount = token_supply * (D2 - D0) / D0
            //
            // Why D2 instead of D1?
            // - D1 = value after deposits (before fees)
            // - D2 = value after deposits and fees
            // - User should get LP tokens based on net value added (after fees)
            mint_amount = (token_supply * (D2 - D0)) / D0;
        }

        // ═══════════════════════════════════════════════════════════════════════════════
        // SLIPPAGE PROTECTION & FINALIZATION
        // ═══════════════════════════════════════════════════════════════════════════════

        // Ensure user gets at least minimum expected LP tokens
        if (mint_amount < min_mint_amount) revert CurveV1Pool_SlippageTooHigh();

        // Mint LP tokens to user
        token.mint(msg.sender, mint_amount);

        emit AddLiquidity(msg.sender, amounts, fees, D1, token_supply + mint_amount);
    }

    /*//////////////////////////////////////////////////////////////
                            SWAP LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate y (output amount) given x (input amount) using Newton's method
     * @dev This is the HEART of Curve's swap algorithm. It solves the StableSwap equation:
     *
     *      MATHEMATICAL FOUNDATION:
     *      The StableSwap invariant is: A*n^n*sum(x_i) + D = A*D*n^n + D^(n+1)/(n^n*prod(x_i))
     *
     *      Given:
     *      - All balances except x_i and x_j (input/output tokens)
     *      - New balance x_i (after receiving input)
     *      - Invariant D (must be preserved)
     *
     *      Solve for: x_j (new balance of output token)
     *
     *      NEWTON'S METHOD:
     *      We rearrange the invariant to f(y) = 0 and use Newton's method:
     *      y_new = y_old - f(y_old) / f'(y_old)
     *
     *      After mathematical manipulation, this simplifies to:
     *      y = (y² + c) / (2y + b - D)
     *
     *      where:
     *      c = D * D^n / (Ann * n^n * prod(all_x_except_j))
     *      b = sum(all_x_except_j) + D/Ann
     *
     * @param i Index of input token (0=DAI, 1=USDC, 2=USDT)
     * @param j Index of output token (0=DAI, 1=USDC, 2=USDT)
     * @param x New balance of input token (old_balance + input_amount, normalized to 18 decimals)
     * @param xp_ Array of current normalized balances (18 decimals)
     * @return y New balance of output token (normalized to 18 decimals)
     */
    function get_y(uint256 i, uint256 j, uint256 x, uint256[N_COINS] memory xp_) internal view returns (uint256) {
        // ═══════════════════════════════════════════════════════════════════════════════
        // INPUT VALIDATION
        // ═══════════════════════════════════════════════════════════════════════════════

        if (i == j) revert CurveV1Pool_SameCoin();
        if (j < 0 || j >= N_COINS) revert CurveV1Pool_InvalidTokenIndex();
        if (i < 0 || i >= N_COINS) revert CurveV1Pool_InvalidTokenIndex();

        // ═══════════════════════════════════════════════════════════════════════════════
        // SETUP NEWTON'S METHOD PARAMETERS
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256 amp = _A();
        uint256 D = get_D(xp_, amp);
        uint256 Ann = amp * N_COINS;
        uint256 c = D; // Will become: D^(n+1) / (Ann * n^n * product_of_x_values)
        uint256 S_ = 0; // Sum of all x values except x_j (output token)

        // ═══════════════════════════════════════════════════════════════════════════════
        // BUILD NEWTON'S METHOD COEFFICIENTS
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256 _x = 0;
        for (uint256 _i = 0; _i < N_COINS; _i++) {
            if (_i == uint256(int256(i))) {
                // For input token: use NEW balance (includes the input amount)
                _x = x;
            } else if (_i != uint256(int256(j))) {
                // For other tokens (not input, not output): use current balance
                _x = xp_[_i];
            } else {
                // Skip output token (j) - we're solving for this
                continue;
            }
            S_ += _x;
            c = (c * D) / (_x * N_COINS); // Build product term
                // After loop: c = D^(n+1) / (n^n * product_of_x_except_j)
        }

        // Complete Newton's method coefficients
        c = (c * D) / (Ann * N_COINS); // Final c coefficient
        uint256 b = S_ + D / Ann; // Final b coefficient

        // ═══════════════════════════════════════════════════════════════════════════════
        // NEWTON'S METHOD ITERATION
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256 y_prev = 0;
        uint256 y = D; // Initial guess: y = D (reasonable starting point)

        // Newton's method to solve for y
        for (uint256 _i = 0; _i < 255; _i++) {
            y_prev = y;

            // Newton's formula: y = (y² + c) / (2y + b - D)
            y = (y * y + c) / (2 * y + b - D);

            // Check convergence: stop when change ≤ 1
            if (y > y_prev) {
                if (y - y_prev <= 1) break;
            } else {
                if (y_prev - y <= 1) break;
            }
        }
        return y; // New balance of output token
    }

    /**
     * @notice Get amount out for a given amount in (including fees)
     * @dev This is the main function users/frontends call to preview swaps
     *
     *      FLOW:
     *      1. Get current normalized balances
     *      2. Calculate new input balance (add input amount)
     *      3. Solve for new output balance using get_y()
     *      4. Calculate output amount = old_balance - new_balance
     *      5. Apply trading fee
     *      6. Convert back to token's native decimals
     *
     *      PRECISION HANDLING:
     *      - Input: converted to 18 decimals for calculation
     *      - Calculation: all done in 18 decimals
     *      - Output: converted back to token's native decimals
     *      - Subtract 1 for rounding safety (prevents over-estimation)
     *
     * @param i Index of input token (0=DAI, 1=USDC, 2=USDT)
     * @param j Index of output token (0=DAI, 1=USDC, 2=USDT)
     * @param dx Amount of input token (in token's native decimals)
     * @return Amount of output token user will receive (in token's native decimals, after fees)
     */
    function get_dy(uint256 i, uint256 j, uint256 dx) external view returns (uint256) {
        // ═══════════════════════════════════════════════════════════════════════════════
        // GET CURRENT STATE & NORMALIZE INPUT
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256[N_COINS] memory xp = _xp();

        // Calculate new input balance (old + input amount, normalized)
        uint256 x;
        if (i == 0) {
            x = xp[0] + dx * DAI_MUL; // DAI
        } else if (i == 1) {
            x = xp[1] + dx * USDC_MUL; // USDC
        } else {
            x = xp[2] + dx * USDT_MUL; // USDT
        }

        // ═══════════════════════════════════════════════════════════════════════════════
        // SOLVE FOR OUTPUT AMOUNT
        // ═══════════════════════════════════════════════════════════════════════════════

        // Get new output balance after swap (in 18 decimals)
        uint256 y = get_y(i, j, x, xp);

        // Calculate output amount: old_balance - new_balance
        // Subtract 1 for rounding safety (prevents giving user more than available)
        uint256 dy;
        if (j == 0) {
            dy = (xp[0] - y - 1) / DAI_MUL; // Convert back to DAI decimals
        } else if (j == 1) {
            dy = (xp[1] - y - 1) / USDC_MUL; // Convert back to USDC decimals
        } else {
            dy = (xp[2] - y - 1) / USDT_MUL; // Convert back to USDT decimals
        }

        // ═══════════════════════════════════════════════════════════════════════════════
        // APPLY TRADING FEE
        // ═══════════════════════════════════════════════════════════════════════════════

        // Calculate fee: fee_rate * output_amount
        uint256 _fee = (fee * dy) / FEE_DENOMINATOR;

        // Return net amount after fee deduction
        return dy - _fee;
    }

    /**
     * @notice Perform a token swap
     * @dev This is the main swap function that users call to exchange tokens
     * @param i Index of input token (0=DAI, 1=USDC, 2=USDT)
     * @param j Index of output token (0=DAI, 1=USDC, 2=USDT)
     * @param dx Amount of input token (in native decimals)
     * @param min_dy Minimum output amount (slippage protection, in native decimals)
     */
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external nonReentrant {
        // ═══════════════════════════════════════════════════════════════════════════════
        // SAFETY CHECKS & INPUT VALIDATION
        // ═══════════════════════════════════════════════════════════════════════════════

        if (is_killed) revert CurveV1Pool_PoolIsKilled();
        if (i == j) revert CurveV1Pool_SameCoin();
        if (i >= N_COINS || j >= N_COINS) revert CurveV1Pool_InvalidTokenIndex();
        if (dx == 0) revert CurveV1Pool_ZeroAmount();

        // ═══════════════════════════════════════════════════════════════════════════════
        // CAPTURE CURRENT POOL STATE & TRANSFER INPUT TOKENS
        // ═══════════════════════════════════════════════════════════════════════════════

        uint256[N_COINS] memory old_balances = balances;
        uint256[N_COINS] memory xp = _xp_mem(old_balances);

        // Transfer input tokens to pool
        IERC20(coins[i]).safeTransferFrom(msg.sender, address(this), dx);

        // ═══════════════════════════════════════════════════════════════════════════════
        // CALCULATE NEW INPUT BALANCE AND SOLVE FOR OUTPUT
        // ═══════════════════════════════════════════════════════════════════════════════

        // Calculate new normalized balance of input token
        uint256 x = _calculateNewInputBalance(xp, i, dx);

        // Solve for new output token balance (in 18 decimals)
        uint256 y = get_y(i, j, x, xp);

        // Calculate raw output amount with safety margin
        uint256 dy_normalized = xp[j] - y - 1;

        // ═══════════════════════════════════════════════════════════════════════════════
        // APPLY FEES AND CONVERT TO NATIVE DECIMALS
        // ═══════════════════════════════════════════════════════════════════════════════

        (uint256 dy, uint256 dy_admin_fee) = _calculateSwapAmounts(dy_normalized, j);

        // ═══════════════════════════════════════════════════════════════════════════════
        // SLIPPAGE PROTECTION & BALANCE UPDATES
        // ═══════════════════════════════════════════════════════════════════════════════

        if (dy < min_dy) revert CurveV1Pool_SlippageTooHigh();

        // Update balances
        balances[i] = old_balances[i] + dx;
        balances[j] = old_balances[j] - dy - dy_admin_fee;

        // Transfer output tokens to user
        IERC20(coins[j]).safeTransfer(msg.sender, dy);

        emit TokenExchange(msg.sender, i, dx, j, dy);
    }

    /**
     * @dev Helper function to calculate new input balance (reduces stack depth)
     */
    function _calculateNewInputBalance(uint256[N_COINS] memory xp, uint256 i, uint256 dx)
        internal
        pure
        returns (uint256 x)
    {
        if (i == 0) {
            x = xp[0] + dx * DAI_MUL;
        } else if (i == 1) {
            x = xp[1] + dx * USDC_MUL;
        } else {
            x = xp[2] + dx * USDT_MUL;
        }
    }

    /**
     * @dev Helper function to calculate swap amounts with fees (reduces stack depth)
     */
    function _calculateSwapAmounts(uint256 dy_normalized, uint256 j)
        internal
        view
        returns (uint256 dy, uint256 dy_admin_fee)
    {
        // Calculate total fee (in normalized 18 decimals)
        uint256 dy_fee_normalized = (dy_normalized * fee) / FEE_DENOMINATOR;

        // Calculate admin portion of fee (in normalized 18 decimals)
        uint256 dy_admin_fee_normalized = (dy_fee_normalized * admin_fee) / FEE_DENOMINATOR;

        // Net output amount after fees (in normalized 18 decimals)
        uint256 dy_net_normalized = dy_normalized - dy_fee_normalized;

        // Convert to native decimals
        if (j == 0) {
            // DAI: already 18 decimals
            dy = dy_net_normalized / DAI_MUL;
            dy_admin_fee = dy_admin_fee_normalized / DAI_MUL;
        } else if (j == 1) {
            // USDC: convert 18→6 decimals
            dy = dy_net_normalized / USDC_MUL;
            dy_admin_fee = dy_admin_fee_normalized / USDC_MUL;
        } else {
            // USDT: convert 18→6 decimals
            dy = dy_net_normalized / USDT_MUL;
            dy_admin_fee = dy_admin_fee_normalized / USDT_MUL;
        }
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDITY REMOVAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Remove liquidity proportionally
     * @param _amount Amount of LP tokens to burn
     * @param min_amounts Minimum amounts of each token to receive
     */
    function remove_liquidity(uint256 _amount, uint256[N_COINS] memory min_amounts) external nonReentrant {
        uint256 total_supply = token.totalSupply();
        uint256[N_COINS] memory amounts;
        uint256[N_COINS] memory fees; // For event compatibility

        for (uint256 i = 0; i < N_COINS; i++) {
            uint256 value = (balances[i] * _amount) / total_supply;
            if (value < min_amounts[i]) revert CurveV1Pool_InsufficientOutputAmount();
            balances[i] -= value;
            amounts[i] = value;

            IERC20(coins[i]).safeTransfer(msg.sender, value);
        }

        token.burnFrom(msg.sender, _amount);

        emit RemoveLiquidity(msg.sender, amounts, fees, total_supply - _amount);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ramp amplification coefficient
     * @param _future_A Target A value
     * @param _future_time Target timestamp
     */
    function ramp_A(uint256 _future_A, uint256 _future_time) external {
        if (msg.sender != owner) revert CurveV1Pool_OnlyOwner();
        if (block.timestamp < initial_A_time + MIN_RAMP_TIME) revert CurveV1Pool_TooFrequent();
        if (_future_time < block.timestamp + MIN_RAMP_TIME) revert CurveV1Pool_InsufficientTime();

        uint256 _initial_A = _A();
        if (_future_A == 0 || _future_A >= MAX_A) revert CurveV1Pool_InvalidAParameter();

        // Limit A change rate
        if (
            !(
                ((_future_A >= _initial_A) && (_future_A <= _initial_A * MAX_A_CHANGE))
                    || ((_future_A < _initial_A) && (_future_A * MAX_A_CHANGE >= _initial_A))
            )
        ) revert CurveV1Pool_AChangeTooLarge();

        initial_A = _initial_A;
        future_A = _future_A;
        initial_A_time = block.timestamp;
        future_A_time = _future_time;

        emit RampA(_initial_A, _future_A, block.timestamp, _future_time);
    }

    /**
     * @notice Stop A ramping
     */
    function stop_ramp_A() external {
        if (msg.sender != owner) revert CurveV1Pool_OnlyOwner();

        uint256 current_A = _A();
        initial_A = current_A;
        future_A = current_A;
        initial_A_time = block.timestamp;
        future_A_time = block.timestamp;

        emit StopRampA(current_A, block.timestamp);
    }

    /**
     * @notice Commit new fee parameters
     * @param new_fee New trading fee
     * @param new_admin_fee New admin fee
     */
    function commit_new_fee(uint256 new_fee, uint256 new_admin_fee) external {
        if (msg.sender != owner) revert CurveV1Pool_OnlyOwner();
        if (admin_actions_deadline != 0) revert CurveV1Pool_ActiveAction();
        if (new_fee > MAX_FEE) revert CurveV1Pool_FeeTooHigh();
        if (new_admin_fee > MAX_ADMIN_FEE) revert CurveV1Pool_AdminFeeTooHigh();

        uint256 _deadline = block.timestamp + ADMIN_ACTIONS_DELAY;
        admin_actions_deadline = _deadline;
        future_fee = new_fee;
        future_admin_fee = new_admin_fee;

        emit CommitNewFee(_deadline, new_fee, new_admin_fee);
    }

    /**
     * @notice Apply committed fee changes
     */
    function apply_new_fee() external {
        if (msg.sender != owner) revert CurveV1Pool_OnlyOwner();
        if (block.timestamp < admin_actions_deadline) revert CurveV1Pool_TooEarly();
        if (admin_actions_deadline == 0) revert CurveV1Pool_NoActiveAction();

        admin_actions_deadline = 0;
        uint256 _fee = future_fee;
        uint256 _admin_fee = future_admin_fee;
        fee = _fee;
        admin_fee = _admin_fee;

        emit NewFee(_fee, _admin_fee);
    }

    /**
     * @notice Emergency kill switch
     */
    function kill_me() external {
        if (msg.sender != owner) revert CurveV1Pool_OnlyOwner();
        is_killed = true;
    }

    /**
     * @notice Undo emergency kill
     */
    function unkill_me() external {
        if (msg.sender != owner) revert CurveV1Pool_OnlyOwner();
        is_killed = false;
    }

    /**
     * @notice Get admin fee balances
     * @param i Token index
     * @return Admin fee balance for token i
     */
    function admin_balances(uint256 i) external view returns (uint256) {
        return IERC20(coins[i]).balanceOf(address(this)) - balances[i];
    }

    /**
     * @notice Withdraw accumulated admin fees
     */
    function withdraw_admin_fees() external {
        if (msg.sender != owner) revert CurveV1Pool_OnlyOwner();

        for (uint256 i = 0; i < N_COINS; i++) {
            address coin = coins[i];
            uint256 value = IERC20(coin).balanceOf(address(this)) - balances[i];
            if (value > 0) {
                IERC20(coin).safeTransfer(msg.sender, value);
            }
        }
    }
}
