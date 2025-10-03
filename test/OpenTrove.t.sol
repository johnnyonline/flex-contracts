// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract OpenTroveTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // there's enough liquidity to borrow the full amount
    function test_openTrove(uint256 _lendAmount, uint256 _borrowAmount) public {
        _lendAmount = bound(_lendAmount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, troveManager.MIN_DEBT(), _lendAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Get the collateral price
        uint256 _collateralPrice = exchange.price();

        // Calculate target collateral ratio (10% above MCR)
        uint256 _targetCollateralRatio = troveManager.MINIMUM_COLLATERAL_RATIO() * 110 / 100;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _borrowAmount * _targetCollateralRatio / _collateralPrice;

        // Pick yo rate
        uint256 _annualInterestRate = troveManager.MIN_ANNUAL_INTEREST_RATE() * 2; // 1%

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _borrowAmount + troveManager.calculate_upfront_fee(_borrowAmount, _annualInterestRate);

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, _annualInterestRate);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _collateralNeeded, "E1");
        assertEq(_trove.annual_interest_rate, _annualInterestRate, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, userBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(_trove.collateral * _collateralPrice / _trove.debt, _targetCollateralRatio, 1e15, "E7"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E8");
        assertEq(sortedTroves.size(), 1, "E9");
        assertEq(sortedTroves.first(), _troveId, "E10");
        assertEq(sortedTroves.last(), _troveId, "E11");
        assertTrue(sortedTroves.contains(_troveId), "E12");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E13");
        assertEq(borrowToken.balanceOf(address(lender)), _lendAmount - _borrowAmount, "E14");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E15");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E16");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * _annualInterestRate, "E17");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E18");
    }

    // borrow more than available liquidity, nothing to redeem, should get less borrow tokens than requested
    function test_openTrove_borrowMoreThanAvailableLiquidity(uint256 _lendAmount, uint256 _borrowAmount) public {
        _lendAmount = bound(_lendAmount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, _lendAmount, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Get the collateral price
        uint256 _collateralPrice = exchange.price();

        // Calculate target collateral ratio (10% above MCR)
        uint256 _targetCollateralRatio = troveManager.MINIMUM_COLLATERAL_RATIO() * 110 / 100;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _borrowAmount * _targetCollateralRatio / _collateralPrice;

        // Pick yo rate
        uint256 _annualInterestRate = troveManager.MIN_ANNUAL_INTEREST_RATE() * 2; // 1%

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _borrowAmount + troveManager.calculate_upfront_fee(_borrowAmount, _annualInterestRate);

        // Cache the available liquidity
        uint256 _availableLiquidity = borrowToken.balanceOf(address(lender));

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, _annualInterestRate);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _collateralNeeded, "E1");
        assertEq(_trove.annual_interest_rate, _annualInterestRate, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, userBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(_trove.collateral * _collateralPrice / _trove.debt, _targetCollateralRatio, 1e15, "E7"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E8");
        assertEq(sortedTroves.size(), 1, "E9");
        assertEq(sortedTroves.first(), _troveId, "E10");
        assertEq(sortedTroves.last(), _troveId, "E11");
        assertTrue(sortedTroves.contains(_troveId), "E12");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E13");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E14");
        assertEq(borrowToken.balanceOf(userBorrower), _availableLiquidity, "E15");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E16");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * _annualInterestRate, "E17");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E18");
    }

    // borrow when there's no liquidity available, but 1 borrower to redeem the entire amount to borrow from
    function test_openTrove_borrowNoAvailableLiquidity_andRedeemAllDebt(uint256 _amount) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Pick yo rate
        uint256 _annualInterestRate = troveManager.MIN_ANNUAL_INTEREST_RATE() * 2; // 1%

        // Get the collateral price
        uint256 _collateralPrice = exchange.price();

        // Calculate target collateral ratio (10% above MCR)
        uint256 _targetCollateralRatio = troveManager.MINIMUM_COLLATERAL_RATIO() * 110 / 100;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * _targetCollateralRatio / _collateralPrice;

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, _annualInterestRate);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _upfrontFee = troveManager.calculate_upfront_fee(_amount, _annualInterestRate);
        uint256 _expectedDebt = _amount + _upfrontFee;
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_amount * 1e18 / _collateralPrice);

        // Open a trove and redeem from the other borrower
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, _annualInterestRate);

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _upfrontFee, "E0");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E1");
        assertEq(_trove.annual_interest_rate, _annualInterestRate, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, anotherUserBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6"); // @todo -- close trove if redeem --> debt below min?

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E7");
        assertEq(_trove.collateral, _collateralNeeded, "E8");
        assertEq(_trove.annual_interest_rate, _annualInterestRate, "E9");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E10");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E11");
        assertEq(_trove.owner, userBorrower, "E12");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E13");
        assertApproxEqRel(_trove.collateral * _collateralPrice / _trove.debt, _targetCollateralRatio, 1e15, "E14"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E15");
        assertEq(sortedTroves.size(), 2, "E16");
        assertEq(sortedTroves.first(), _troveIdAnotherBorrower, "E17");
        assertEq(sortedTroves.last(), _troveId, "E18");
        assertTrue(sortedTroves.contains(_troveId), "E19");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E20");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded + _expectedCollateralAfterRedemption, "E21");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E22");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E23"); // @todo -- here -- slippage is fine, but that's too much. update fork and decrease fuzzing range?
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount, "E24");

        // // Check global info
        // assertEq(troveManager.total_debt(), _expectedDebt, "E15");
        // assertEq(troveManager.total_weighted_debt(), _expectedDebt * _annualInterestRate, "E16");
        // assertEq(troveManager.collateral_balance(), _collateralNeeded, "E17");
    }

    // borrow when there's some liquidity available, and 1 borrower to redeem from
    // test_openTrove_borrowMoreThanAvailableLiquidity_andRedeem

    // -------

    // function test_openTrove_zeroCollateral
    // function test_openTrove_zeroDebt
    // function test_openTrove_rateTooLow
    // function test_openTrove_rateTooHigh
    // function test_openTrove_troveExists
    // function test_openTrove_upfrontFeeTooHigh
    // function test_openTrove_debtTooLow
    // function test_openTrove_belowMCR
    // function test_openTrove_debtOutTooLow

}
