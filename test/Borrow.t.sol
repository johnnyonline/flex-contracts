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
    function test_borrowFromActiveTrove(
        uint256 _lendAmount,
        uint256 _borrowAmount
    ) public {
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
        uint256 _expectedDebt =
            _borrowAmount + troveManager.get_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove
        uint256 _troveId =
            mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _collateralNeeded, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, userBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(
            _trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO * 2, 1e15, "E7"
        ); // 0.1%

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
        assertEq(troveManager.zombie_trove_id(), 0, "E20");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E21");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E22");

        // Finally borrow more from the trove
        vm.prank(userBorrower);
        troveManager.borrow(_troveId, _borrowAmount, type(uint256).max, 0);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt * 2, "E23");
        assertEq(_trove.collateral, _collateralNeeded, "E24");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E25");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E26");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E27");
        assertEq(_trove.owner, userBorrower, "E28");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E29");
        assertApproxEqRel(
            _trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E30"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E31");
        assertEq(sortedTroves.size(), 1, "E32");
        assertEq(sortedTroves.first(), _troveId, "E33");
        assertEq(sortedTroves.last(), _troveId, "E34");
        assertTrue(sortedTroves.contains(_troveId), "E35");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E36");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E37");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E38");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E39");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E40");
        assertEq(borrowToken.balanceOf(userBorrower), _totalBorrowAmount, "E41");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E42");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E43");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E44");
        assertEq(troveManager.zombie_trove_id(), 0, "E45");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E46");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E47");
    }

    // 1. lend
    // 2. open trove with min debt
    // 3. borrow all available liquidity from trove (and more)
    function test_borrowFromActiveTrove_borrowMoreThanAvailableLiquidity(
        uint256 _lendAmount,
        uint256 _borrowAmount
    ) public {
        _lendAmount = bound(_lendAmount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, _lendAmount, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_borrowAmount + troveManager.MIN_DEBT()) * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = troveManager.MIN_DEBT()
            + troveManager.get_upfront_fee(troveManager.MIN_DEBT(), DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache the available liquidity
        uint256 _availableLiquidity = borrowToken.balanceOf(address(lender));

        // Open a trove
        uint256 _troveId =
            mintAndOpenTrove(userBorrower, _collateralNeeded, troveManager.MIN_DEBT(), DEFAULT_ANNUAL_INTEREST_RATE);

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
        assertEq(troveManager.zombie_trove_id(), 0, "E21");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E22");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E23");

        // Calculate expected debt after second borrow
        uint256 _secondExpectedDebt =
            _expectedDebt + _borrowAmount + troveManager.get_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally borrow more from the trove
        vm.prank(userBorrower);
        troveManager.borrow(_troveId, _borrowAmount, type(uint256).max, 0);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E23");
        assertEq(_trove.collateral, _collateralNeeded, "E24");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E25");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E26");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E27");
        assertEq(_trove.owner, userBorrower, "E28");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E29");
        assertApproxEqRel(
            _trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E30"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E31");
        assertEq(sortedTroves.size(), 1, "E32");
        assertEq(sortedTroves.first(), _troveId, "E33");
        assertEq(sortedTroves.last(), _troveId, "E34");
        assertTrue(sortedTroves.contains(_troveId), "E35");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E36");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E37");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E38");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E39");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E40");
        assertEq(borrowToken.balanceOf(userBorrower), _lendAmount, "E41");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E42");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E43");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E44");
        assertEq(troveManager.zombie_trove_id(), 0, "E45");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E46");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E47");
    }

    function test_borrowFromActiveTrove_zeroDebt(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow 0 debt
        vm.prank(userBorrower);
        vm.expectRevert("!debt_amount");
        troveManager.borrow(_troveId, 0, type(uint256).max, 0);
    }

    function test_borrowFromActiveTrove_notOwner(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow from trove as not owner
        vm.prank(anotherUserBorrower);
        vm.expectRevert("!owner");
        troveManager.borrow(_troveId, _amount, type(uint256).max, 0);
    }

    function test_borrowFromActiveTrove_notActiveTrove(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Pull enough liquidity to make trove a zombie trove (but above 0 debt)
        uint256 _amountToPull = _amount - 100 ether;

        // Pull liquidity from lender to make trove a zombie trove (but above 0 debt)
        vm.prank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);

        // Make sure trove is a zombie trove
        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.zombie), "E25");

        // Try to borrow from a non-active trove
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.borrow(_troveId, _amount, type(uint256).max, 0);
    }

    function test_borrowFromActiveTrove_upfrontFeeTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow with upfront fee too high
        vm.prank(userBorrower);
        vm.expectRevert("!max_upfront_fee");
        troveManager.borrow(_troveId, _amount, 0, 0);
    }

    function test_borrowFromActiveTrove_belowMCR(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate the maximum amount that can be borrowed while staying above MCR
        uint256 _maxBorrowable = (_collateralNeeded * exchange.price()) / troveManager.MINIMUM_COLLATERAL_RATIO();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow more than is allowed while staying above MCR
        vm.prank(userBorrower);
        vm.expectRevert("!MINIMUM_COLLATERAL_RATIO");
        troveManager.borrow(_troveId, _maxBorrowable, type(uint256).max, 0);
    }

    function test_borrowFromActiveTrove_notEnoughDebtOut(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow with max debt out
        vm.prank(userBorrower);
        vm.expectRevert("shrekt");
        troveManager.borrow(_troveId, 1, type(uint256).max, type(uint256).max);
    }

}
