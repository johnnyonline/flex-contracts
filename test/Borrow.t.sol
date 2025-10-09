// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract BorrowTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // 1. lend
    // 2. borrow max half of available liquidity
    // 3. borrow same amount again from trove
    function test_borrowFromActiveTrove(uint256 _lendAmount, uint256 _borrowAmount) public {
        _lendAmount = bound(_lendAmount, troveManager.MIN_DEBT() * 2, maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, troveManager.MIN_DEBT() * 2, _lendAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Cut in half so we can borrow twice
        _borrowAmount = _borrowAmount / 2;

        // Total amount we'll be borrowing
        uint256 _totalBorrowAmount = _borrowAmount * 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _totalBorrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _borrowAmount + troveManager.calculate_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _collateralNeeded, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, userBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO * 2, 1e15, "E7"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E8");
        assertEq(sortedTroves.size(), 1, "E9");
        assertEq(sortedTroves.first(), _troveId, "E10");
        assertEq(sortedTroves.last(), _troveId, "E11");
        assertTrue(sortedTroves.contains(_troveId), "E12");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E13");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E14");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E15");
        assertEq(borrowToken.balanceOf(address(lender)), _lendAmount - _borrowAmount, "E16");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E18");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E19");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E20");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E21");

        // Finally borrow more from the trove
        vm.prank(userBorrower);
        troveManager.borrow(_troveId, _borrowAmount, type(uint256).max, 0);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt * 2, "E22");
        assertEq(_trove.collateral, _collateralNeeded, "E23");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E24");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E25");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E26");
        assertEq(_trove.owner, userBorrower, "E27");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E28");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E29"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E30");
        assertEq(sortedTroves.size(), 1, "E31");
        assertEq(sortedTroves.first(), _troveId, "E32");
        assertEq(sortedTroves.last(), _troveId, "E33");
        assertTrue(sortedTroves.contains(_troveId), "E34");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E35");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E36");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E37");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E38");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E39");
        assertEq(borrowToken.balanceOf(userBorrower), _totalBorrowAmount, "E40");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E41");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E42");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E43");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E44");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E45");
    }

    // 1. lend
    // 2. open trove with min debt
    // 3. borrow all available liquidity from trove (and more)
    function test_borrowFromActiveTrove_borrowMoreThanAvailableLiquidity(uint256 _lendAmount, uint256 _borrowAmount) public {
        _lendAmount = bound(_lendAmount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, _lendAmount, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = (_borrowAmount + troveManager.MIN_DEBT()) * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = troveManager.MIN_DEBT() + troveManager.calculate_upfront_fee(troveManager.MIN_DEBT(), DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache the available liquidity
        uint256 _availableLiquidity = borrowToken.balanceOf(address(lender));

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, troveManager.MIN_DEBT(), DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _collateralNeeded, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, userBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertGt(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E7");

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E8");
        assertEq(sortedTroves.size(), 1, "E9");
        assertEq(sortedTroves.first(), _troveId, "E10");
        assertEq(sortedTroves.last(), _troveId, "E11");
        assertTrue(sortedTroves.contains(_troveId), "E12");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E13");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E14");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E15");
        assertEq(borrowToken.balanceOf(address(lender)), _lendAmount - troveManager.MIN_DEBT(), "E16");
        assertEq(borrowToken.balanceOf(userBorrower), troveManager.MIN_DEBT(), "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E19");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E20");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E21");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E22");

        // Calculate expected debt after second borrow
        uint256 _secondExpectedDebt = _expectedDebt + _borrowAmount + troveManager.calculate_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally borrow more from the trove
        vm.prank(userBorrower);
        troveManager.borrow(_troveId, _borrowAmount, type(uint256).max, 0);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E22");
        assertEq(_trove.collateral, _collateralNeeded, "E23");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E24");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E25");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E26");
        assertEq(_trove.owner, userBorrower, "E27");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E28");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E29"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E30");
        assertEq(sortedTroves.size(), 1, "E31");
        assertEq(sortedTroves.first(), _troveId, "E32");
        assertEq(sortedTroves.last(), _troveId, "E33");
        assertTrue(sortedTroves.contains(_troveId), "E34");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E35");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E36");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E37");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E38");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E39");
        assertEq(borrowToken.balanceOf(userBorrower), _lendAmount, "E40");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E41");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E42");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E43");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E44");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E45");
    }

    // ------- @todo

    // function test_borrowFromActiveTrove_zeroDebt
    // function test_borrowFromActiveTrove_notActiveTrove
    // function test_borrowFromActiveTrove_upfrontFeeTooHigh
    // function test_borrowFromActiveTrove_belowMCR
    // function test_borrowFromActiveTrove_notEnoughDebtOut
}