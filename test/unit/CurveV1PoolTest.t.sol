// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {CurveV1Pool} from "../../src/CurveV1Pool.sol";
import {CurveLPToken} from "../../src/CurveLPToken.sol";
import {MockDAI} from "../mocks/MockDAI.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockUSDT} from "../mocks/MockUSDT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CurveV1PoolTest - Comprehensive Unit Tests for Curve V1 Pool
 * @author Rosa Hadi
 * @notice Tests all core functionality of the Curve StableSwap pool
 */
contract CurveV1PoolTest is Test {
    /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    CurveV1Pool public pool;
    CurveLPToken public lpToken;
    MockDAI public dai;
    MockUSDC public usdc;
    MockUSDT public usdt;

    // Test accounts
    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    // Pool parameters
    uint256 public constant INITIAL_A = 2000;
    uint256 public constant INITIAL_FEE = 4000000; // 0.04%
    uint256 public constant INITIAL_ADMIN_FEE = 5000000000; // 50%
    uint256 public constant MIN_RAMP_TIME = 86400;

    // Test amounts
    uint256 public constant INITIAL_BALANCE = 1_000_000e18; // 1M of each token
    uint256 public constant LARGE_AMOUNT = 100_000e18; // 100k DAI
    uint256 public constant MEDIUM_AMOUNT = 10_000e18; // 10k DAI
    uint256 public constant SMALL_AMOUNT = 1_000e18; // 1k DAI

    /*//////////////////////////////////////////////////////////////
                              SETUP FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Deploy mock tokens
        dai = new MockDAI();
        usdc = new MockUSDC();
        usdt = new MockUSDT();

        // Deploy LP token
        lpToken = new CurveLPToken(
            "Curve.fi DAI/USDC/USDT",
            "3CRV",
            address(0),
            owner
        );

        // Deploy pool
        address[3] memory coins = [address(dai), address(usdc), address(usdt)];
        pool = new CurveV1Pool(owner, coins, address(lpToken), INITIAL_A, INITIAL_FEE, INITIAL_ADMIN_FEE);

        // Set pool as minter
        vm.prank(owner);
        lpToken.setMinter(address(pool));

        // Fund test accounts
        _setupTestAccounts();
    }

    function _setupTestAccounts() internal {
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = charlie;

        for (uint256 i = 0; i < accounts.length; i++) {
            // Mint tokens to test accounts
            dai.mint(accounts[i], INITIAL_BALANCE);
            usdc.mint(accounts[i], INITIAL_BALANCE / 1e12);
            usdt.mint(accounts[i], INITIAL_BALANCE / 1e12);

            // Approve pool to spend tokens
            vm.startPrank(accounts[i]);
            dai.approve(address(pool), type(uint256).max);
            usdc.approve(address(pool), type(uint256).max);
            usdt.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _addInitialLiquidity() internal {
        uint256[3] memory amounts = [LARGE_AMOUNT, LARGE_AMOUNT / 1e12, LARGE_AMOUNT / 1e12];

        vm.prank(alice);
        pool.add_liquidity(amounts, 0);
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ConstructorSetsCorrectValues() public {
        assertEq(pool.owner(), owner);
        assertEq(pool.A(), INITIAL_A);
        assertEq(pool.fee(), INITIAL_FEE);
        assertEq(pool.admin_fee(), INITIAL_ADMIN_FEE);
        assertEq(address(pool.token()), address(lpToken));
        assertEq(pool.coins(0), address(dai));
        assertEq(pool.coins(1), address(usdc));
        assertEq(pool.coins(2), address(usdt));
        assertFalse(pool.is_killed());
    }

    function test_ConstructorRevertsOnInvalidInputs() public {
        address[3] memory invalidCoins;

        // Test invalid coin address
        vm.expectRevert(CurveV1Pool.CurveV1Pool_InvalidCoinAddress.selector);
        new CurveV1Pool(owner, invalidCoins, address(lpToken), INITIAL_A, INITIAL_FEE, INITIAL_ADMIN_FEE);

        // Test invalid pool token
        address[3] memory validCoins = [address(dai), address(usdc), address(usdt)];
        vm.expectRevert(CurveV1Pool.CurveV1Pool_InvalidPoolToken.selector);
        new CurveV1Pool(owner, validCoins, address(0), INITIAL_A, INITIAL_FEE, INITIAL_ADMIN_FEE);

        // Test invalid A parameter
        vm.expectRevert(CurveV1Pool.CurveV1Pool_InvalidAParameter.selector);
        new CurveV1Pool(owner, validCoins, address(lpToken), 0, INITIAL_FEE, INITIAL_ADMIN_FEE);

        // Test fee too high
        vm.expectRevert(CurveV1Pool.CurveV1Pool_FeeTooHigh.selector);
        new CurveV1Pool(owner, validCoins, address(lpToken), INITIAL_A, 6 * 10 ** 9, INITIAL_ADMIN_FEE);

        // Test admin fee too high
        vm.expectRevert(CurveV1Pool.CurveV1Pool_AdminFeeTooHigh.selector);
        new CurveV1Pool(owner, validCoins, address(lpToken), INITIAL_A, INITIAL_FEE, 11 * 10 ** 9);
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InitialLiquidityAddition() public {
        uint256[3] memory amounts = [LARGE_AMOUNT, LARGE_AMOUNT / 1e12, LARGE_AMOUNT / 1e12];

        vm.prank(alice);
        pool.add_liquidity(amounts, 0);

        // Check balances updated
        assertEq(pool.balances(0), amounts[0]);
        assertEq(pool.balances(1), amounts[1]);
        assertEq(pool.balances(2), amounts[2]);

        // Check LP tokens minted
        uint256 lpBalance = lpToken.balanceOf(alice);
        assertTrue(lpBalance > 0);

        // Check virtual price
        uint256 virtualPrice = pool.get_virtual_price();
        assertEq(virtualPrice, 1e18); // Should be 1.0 for initial deposit
    }

    function test_InitialDepositRequiresAllCoins() public {
        uint256[3] memory amounts = [LARGE_AMOUNT, 0, LARGE_AMOUNT / 1e12]; // Missing USDC

        vm.expectRevert(CurveV1Pool.CurveV1Pool_InitialDepositRequiresAllCoins.selector);
        vm.prank(alice);
        pool.add_liquidity(amounts, 0);
    }

    function test_SubsequentLiquidityAddition() public {
        _addInitialLiquidity();

        uint256 lpBalanceBefore = lpToken.balanceOf(bob);
        uint256[3] memory amounts = [MEDIUM_AMOUNT, MEDIUM_AMOUNT / 1e12, MEDIUM_AMOUNT / 1e12];

        vm.prank(bob);
        pool.add_liquidity(amounts, 0);

        uint256 lpBalanceAfter = lpToken.balanceOf(bob);
        assertTrue(lpBalanceAfter > lpBalanceBefore);
    }

    function test_ImbalancedLiquidityAddition() public {
        _addInitialLiquidity();

        // Add imbalanced liquidity (only DAI)
        uint256[3] memory amounts = [MEDIUM_AMOUNT, 0, 0];

        vm.prank(bob);
        pool.add_liquidity(amounts, 0);

        // Should receive fewer LP tokens due to imbalance fees
        uint256 lpBalance = lpToken.balanceOf(bob);
        assertTrue(lpBalance > 0);
    }

    function test_AddLiquiditySlippageProtection() public {
        _addInitialLiquidity();

        uint256[3] memory amounts = [MEDIUM_AMOUNT, MEDIUM_AMOUNT / 1e12, MEDIUM_AMOUNT / 1e12];
        uint256 unrealisticMinMint = 1e25; // Unrealistically high

        vm.expectRevert(CurveV1Pool.CurveV1Pool_SlippageTooHigh.selector);
        vm.prank(bob);
        pool.add_liquidity(amounts, unrealisticMinMint);
    }

    function test_CalcTokenAmount() public {
        _addInitialLiquidity();

        uint256[3] memory amounts = [MEDIUM_AMOUNT, MEDIUM_AMOUNT / 1e12, MEDIUM_AMOUNT / 1e12];

        uint256 estimatedTokens = pool.calc_token_amount(amounts, true);
        assertTrue(estimatedTokens > 0);

        // Estimate should be close to actual (within reasonable range)
        vm.prank(bob);
        pool.add_liquidity(amounts, 0);
        uint256 actualTokens = lpToken.balanceOf(bob);

        // Allow 5% difference due to fees not included in calc_token_amount
        uint256 difference =
            actualTokens > estimatedTokens ? actualTokens - estimatedTokens : estimatedTokens - actualTokens;
        assertTrue(difference <= estimatedTokens * 5 / 100);
    }

    /*//////////////////////////////////////////////////////////////
                          REMOVAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RemoveLiquidityProportional() public {
        _addInitialLiquidity();

        uint256 lpBalance = lpToken.balanceOf(alice);
        uint256 removeAmount = lpBalance / 2; // Remove half

        uint256[3] memory minAmounts = [uint256(0), uint256(0), uint256(0)];

        vm.prank(alice);
        pool.remove_liquidity(removeAmount, minAmounts);

        // Check LP tokens burned
        assertEq(lpToken.balanceOf(alice), lpBalance - removeAmount);

        // Check tokens received proportionally
        assertTrue(dai.balanceOf(alice) > INITIAL_BALANCE - LARGE_AMOUNT);
        assertTrue(usdc.balanceOf(alice) > INITIAL_BALANCE / 1e12 - LARGE_AMOUNT / 1e12);
        assertTrue(usdt.balanceOf(alice) > INITIAL_BALANCE / 1e12 - LARGE_AMOUNT / 1e12);
    }

    function test_RemoveLiquiditySlippageProtection() public {
        _addInitialLiquidity();

        uint256 lpBalance = lpToken.balanceOf(alice);
        uint256 removeAmount = lpBalance / 2;

        // Set unrealistic minimum amounts
        uint256[3] memory minAmounts = [uint256(1e25), uint256(1e25), uint256(1e25)];

        vm.expectRevert(CurveV1Pool.CurveV1Pool_InsufficientOutputAmount.selector);
        vm.prank(alice);
        pool.remove_liquidity(removeAmount, minAmounts);
    }

    /*//////////////////////////////////////////////////////////////
                              SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_BasicSwap() public {
        _addInitialLiquidity();

        uint256 swapAmount = SMALL_AMOUNT;
        uint256 daiBalanceBefore = dai.balanceOf(bob);
        uint256 usdcBalanceBefore = usdc.balanceOf(bob);

        // Get expected output
        uint256 expectedOut = pool.get_dy(0, 1, swapAmount); // DAI -> USDC

        vm.prank(bob);
        pool.exchange(0, 1, swapAmount, expectedOut);

        // Check balances changed
        assertEq(dai.balanceOf(bob), daiBalanceBefore - swapAmount);
        assertTrue(usdc.balanceOf(bob) >= usdcBalanceBefore + expectedOut);
    }

    function test_SwapRevertsOnSameCoin() public {
        _addInitialLiquidity();

        vm.expectRevert(CurveV1Pool.CurveV1Pool_SameCoin.selector);
        vm.prank(bob);
        pool.exchange(0, 0, SMALL_AMOUNT, 0);
    }

    function test_SwapRevertsOnInvalidIndex() public {
        _addInitialLiquidity();

        vm.expectRevert(CurveV1Pool.CurveV1Pool_InvalidTokenIndex.selector);
        vm.prank(bob);
        pool.exchange(0, 5, SMALL_AMOUNT, 0);
    }

    function test_SwapSlippageProtection() public {
        _addInitialLiquidity();

        uint256 swapAmount = SMALL_AMOUNT;
        uint256 expectedOut = pool.get_dy(0, 1, swapAmount);
        uint256 unrealisticMinOut = expectedOut * 2; // Double the expected output

        vm.expectRevert(CurveV1Pool.CurveV1Pool_SlippageTooHigh.selector);
        vm.prank(bob);
        pool.exchange(0, 1, swapAmount, unrealisticMinOut);
    }

    function test_GetDyReturnsCorrectAmount() public {
        _addInitialLiquidity();

        uint256 swapAmount = SMALL_AMOUNT;
        uint256 expectedOut = pool.get_dy(0, 1, swapAmount);

        assertTrue(expectedOut > 0);
        assertTrue(expectedOut < swapAmount); // Should be less due to decimals and fees
    }

    function test_LargeSwapHasHigherSlippage() public {
        _addInitialLiquidity();

        uint256 smallSwap = SMALL_AMOUNT;
        uint256 largeSwap = LARGE_AMOUNT / 10;

        uint256 smallOut = pool.get_dy(0, 1, smallSwap);
        uint256 largeOut = pool.get_dy(0, 1, largeSwap);

        // Large swap should have worse rate due to slippage
        uint256 smallRate = (smallOut * 1e18) / smallSwap;
        uint256 largeRate = (largeOut * 1e18) / largeSwap;

        assertTrue(smallRate > largeRate);
    }

    function test_SwapUpdatesFees() public {
        _addInitialLiquidity();

        uint256 adminBalanceBefore = pool.admin_balances(1); // USDC admin fees

        vm.prank(bob);
        pool.exchange(0, 1, LARGE_AMOUNT, 0);

        uint256 adminBalanceAfter = pool.admin_balances(1);
        assertTrue(adminBalanceAfter > adminBalanceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                          AMPLIFICATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ARamping() public {
        // Wait for MIN_RAMP_TIME to pass from constructor
        vm.warp(block.timestamp + MIN_RAMP_TIME + 1);

        uint256 newA = 4000;
        uint256 futureTime = block.timestamp + 86400; // 1 day from now

        vm.prank(owner);
        pool.ramp_A(newA, futureTime);

        assertEq(pool.future_A(), newA);
        assertEq(pool.future_A_time(), futureTime);
    }

    function test_ARampingRevertsOnInvalidParameters() public {
        // First, we need to wait for MIN_RAMP_TIME to pass from constructor
        vm.warp(block.timestamp + MIN_RAMP_TIME + 1);

        // Test too large A change
        uint256 currentA = pool.A();
        uint256 tooLargeA = currentA * 15; // More than 10x increase
        uint256 futureTime = block.timestamp + 86400;

        vm.expectRevert(CurveV1Pool.CurveV1Pool_AChangeTooLarge.selector);
        vm.prank(owner);
        pool.ramp_A(tooLargeA, futureTime);

        // Test zero A
        vm.expectRevert(CurveV1Pool.CurveV1Pool_InvalidAParameter.selector);
        vm.prank(owner);
        pool.ramp_A(0, futureTime);

        // Test too large A (over MAX_A)
        vm.expectRevert(CurveV1Pool.CurveV1Pool_InvalidAParameter.selector);
        vm.prank(owner);
        pool.ramp_A(2000000, futureTime); // Way over MAX_A

        // Test insufficient time
        vm.expectRevert(CurveV1Pool.CurveV1Pool_InsufficientTime.selector);
        vm.prank(owner);
        pool.ramp_A(currentA * 2, block.timestamp + 100); // Less than MIN_RAMP_TIME
    }

    function test_ARampingReturnsIntermediateValues() public {
        // Wait for MIN_RAMP_TIME to pass from constructor
        vm.warp(block.timestamp + MIN_RAMP_TIME + 1);

        uint256 initialA = pool.A();
        uint256 newA = 4000;
        uint256 rampDuration = 86400; // 1 day
        uint256 futureTime = block.timestamp + rampDuration;

        vm.prank(owner);
        pool.ramp_A(newA, futureTime);

        // Fast forward to middle of ramp
        vm.warp(block.timestamp + rampDuration / 2);

        uint256 midpointA = pool.A();
        assertTrue(midpointA > initialA);
        assertTrue(midpointA < newA);
    }

    function test_StopRampA() public {
        // Wait for MIN_RAMP_TIME to pass from constructor
        vm.warp(block.timestamp + MIN_RAMP_TIME + 1);

        uint256 newA = 4000;
        uint256 futureTime = block.timestamp + 86400;

        vm.prank(owner);
        pool.ramp_A(newA, futureTime);

        // Fast forward partway
        vm.warp(block.timestamp + 43200); // 12 hours
        uint256 currentA = pool.A();

        vm.prank(owner);
        pool.stop_ramp_A();

        assertEq(pool.future_A(), currentA);
        assertEq(pool.initial_A(), currentA);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CommitNewFee() public {
        uint256 newFee = 2000000; // 0.02%
        uint256 newAdminFee = 6000000000; // 60%

        vm.prank(owner);
        pool.commit_new_fee(newFee, newAdminFee);

        assertEq(pool.future_fee(), newFee);
        assertEq(pool.future_admin_fee(), newAdminFee);
        assertTrue(pool.admin_actions_deadline() > block.timestamp);
    }

    function test_ApplyNewFee() public {
        uint256 newFee = 2000000;
        uint256 newAdminFee = 6000000000;

        vm.prank(owner);
        pool.commit_new_fee(newFee, newAdminFee);

        // Fast forward past deadline
        vm.warp(pool.admin_actions_deadline() + 1);

        vm.prank(owner);
        pool.apply_new_fee();

        assertEq(pool.fee(), newFee);
        assertEq(pool.admin_fee(), newAdminFee);
        assertEq(pool.admin_actions_deadline(), 0);
    }

    function test_WithdrawAdminFees() public {
        _addInitialLiquidity();

        // Generate some fees through swaps
        vm.prank(bob);
        pool.exchange(0, 1, LARGE_AMOUNT, 0);

        uint256 adminUSDCBefore = usdc.balanceOf(owner);
        uint256 adminFeeBalance = pool.admin_balances(1);

        vm.prank(owner);
        pool.withdraw_admin_fees();

        uint256 adminUSDCAfter = usdc.balanceOf(owner);
        assertEq(adminUSDCAfter, adminUSDCBefore + adminFeeBalance);
    }

    function test_KillSwitch() public {
        vm.prank(owner);
        pool.kill_me();

        assertTrue(pool.is_killed());

        // Should revert on operations
        uint256[3] memory amounts = [SMALL_AMOUNT, SMALL_AMOUNT / 1e12, SMALL_AMOUNT / 1e12];
        vm.expectRevert(CurveV1Pool.CurveV1Pool_PoolIsKilled.selector);
        vm.prank(alice);
        pool.add_liquidity(amounts, 0);

        vm.expectRevert(CurveV1Pool.CurveV1Pool_PoolIsKilled.selector);
        vm.prank(alice);
        pool.exchange(0, 1, SMALL_AMOUNT, 0);
    }

    function test_UnkillSwitch() public {
        vm.prank(owner);
        pool.kill_me();
        assertTrue(pool.is_killed());

        vm.prank(owner);
        pool.unkill_me();
        assertFalse(pool.is_killed());
    }

    function test_OnlyOwnerModifierWorks() public {
        vm.expectRevert(CurveV1Pool.CurveV1Pool_OnlyOwner.selector);
        vm.prank(alice);
        pool.ramp_A(4000, block.timestamp + 86400);

        vm.expectRevert(CurveV1Pool.CurveV1Pool_OnlyOwner.selector);
        vm.prank(alice);
        pool.commit_new_fee(2000000, 6000000000);

        vm.expectRevert(CurveV1Pool.CurveV1Pool_OnlyOwner.selector);
        vm.prank(alice);
        pool.kill_me();
    }

    /*//////////////////////////////////////////////////////////////
                          VIRTUAL PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_VirtualPriceIncreasesWithFees() public {
        _addInitialLiquidity();

        uint256 virtualPriceBefore = pool.get_virtual_price();

        // Generate fees through swaps
        vm.prank(bob);
        pool.exchange(0, 1, LARGE_AMOUNT, 0);

        uint256 virtualPriceAfter = pool.get_virtual_price();
        assertTrue(virtualPriceAfter > virtualPriceBefore);
    }

    function test_VirtualPriceStartsAtOne() public {
        uint256[3] memory amounts = [LARGE_AMOUNT, LARGE_AMOUNT / 1e12, LARGE_AMOUNT / 1e12];

        vm.prank(alice);
        pool.add_liquidity(amounts, 0);

        uint256 virtualPrice = pool.get_virtual_price();
        assertEq(virtualPrice, 1e18); // Should be exactly 1.0
    }

    /*//////////////////////////////////////////////////////////////
                          EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ZeroAmountSwapReverts() public {
        _addInitialLiquidity();

        vm.expectRevert(CurveV1Pool.CurveV1Pool_ZeroAmount.selector);
        vm.prank(bob);
        pool.exchange(0, 1, 0, 0);
    }

    function test_SwapWithEmptyPoolReverts() public {
        // Try to swap without any liquidity
        vm.expectRevert(); // Should revert due to division by zero in calculations
        vm.prank(bob);
        pool.exchange(0, 1, SMALL_AMOUNT, 0);
    }

    function test_VerySmallSwap() public {
        _addInitialLiquidity();

        uint256 tinyAmount = 1; // 1 wei
        uint256 expectedOut = pool.get_dy(0, 1, tinyAmount);

        if (expectedOut > 0) {
            vm.prank(bob);
            pool.exchange(0, 1, tinyAmount, 0);
        }
        // If expectedOut is 0, the swap might not be profitable due to fees
    }

    function test_MaximumSwap() public {
        _addInitialLiquidity();

        // Try to swap more than available (should work due to curve math)
        uint256 maxAmount = LARGE_AMOUNT / 2;
        uint256 expectedOut = pool.get_dy(0, 1, maxAmount);

        vm.prank(bob);
        pool.exchange(0, 1, maxAmount, expectedOut);
    }

    /*//////////////////////////////////////////////////////////////
                          INVARIANT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InvariantPreservation() public {
        _addInitialLiquidity();

        // Calculate initial D
        uint256[3] memory xp;
        xp[0] = pool.balances(0) * 1; // DAI multiplier
        xp[1] = pool.balances(1) * 1e12; // USDC multiplier
        xp[2] = pool.balances(2) * 1e12; // USDT multiplier

        // After swap, D should be approximately the same (accounting for fees)
        uint256 swapAmount = MEDIUM_AMOUNT;
        vm.prank(bob);
        pool.exchange(0, 1, swapAmount, 0);

        // The invariant should be preserved (approximately, due to fees)
        uint256 virtualPriceAfter = pool.get_virtual_price();
        assertTrue(virtualPriceAfter >= 1e18); // Should not decrease below 1.0
    }

    /*//////////////////////////////////////////////////////////////
                              HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetTokenAddresses() public {
        assertEq(pool.coins(0), address(dai));
        assertEq(pool.coins(1), address(usdc));
        assertEq(pool.coins(2), address(usdt));
    }

    function test_BalanceAccounting() public {
        _addInitialLiquidity();

        // Check that pool balances match what was deposited
        assertEq(pool.balances(0), LARGE_AMOUNT);
        assertEq(pool.balances(1), LARGE_AMOUNT / 1e12);
        assertEq(pool.balances(2), LARGE_AMOUNT / 1e12);

        // Check that actual token balances are at least the recorded balances
        assertTrue(dai.balanceOf(address(pool)) >= pool.balances(0));
        assertTrue(usdc.balanceOf(address(pool)) >= pool.balances(1));
        assertTrue(usdt.balanceOf(address(pool)) >= pool.balances(2));
    }
}
