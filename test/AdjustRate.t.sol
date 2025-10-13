// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract AdjustRateTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. adjust rate (no upfront fee)
    function test_adjustRate(uint256 _amount) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _amount = troveManager.MIN_DEBT();

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _collateralNeeded, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, userBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E7"); // 0.1%

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
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E16");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E18");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E19");
        assertEq(troveManager.zombie_trove_id(), 0, "E20");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E21");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E22");

        // Skip time to be able to adjust the rate again without upfront fee
        skip(troveManager.INTEREST_RATE_ADJ_COOLDOWN());

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);

        // Check everything again

        // Calculate expected debt with interest accumulated
        uint256 _secondExpectedDebt = _expectedDebt + ((_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - _trove.last_debt_update_time)) / (365 days * 1e18));

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E23");
        assertEq(_trove.collateral, _collateralNeeded, "E24");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E25");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E26");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E27");
        assertEq(_trove.owner, userBorrower, "E28");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E29");
        assertLt(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E30"); // increased debt --> lower CR

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
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E41");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E42");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * _newAnnualInterestRate, "E43");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E44");
        assertEq(troveManager.zombie_trove_id(), 0, "E45");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E46");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E47");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip only half of the rate cooldown period and adjust rate prematurely (with upfront fee)
    function test_adjustRate_prematurely(uint256 _amount) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _collateralNeeded, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, userBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E7"); // 0.1%

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
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E16");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E18");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E19");
        assertEq(troveManager.zombie_trove_id(), 0, "E20");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E21");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E22");

        // Skip time but still be within the cooldown period
        skip(troveManager.INTEREST_RATE_ADJ_COOLDOWN() / 2);

        // Double the interest rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%

        // Calculate second expected debt with interest accumulated
        uint256 _interestOnFirstDebt = _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - _trove.last_debt_update_time) / (365 days * 1e18);
        uint256 _secondExpectedDebt = _expectedDebt + _interestOnFirstDebt + troveManager.get_upfront_fee(_expectedDebt + _interestOnFirstDebt, _newAnnualInterestRate);

        // Finally adjust the rate
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, type(uint256).max);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E23");
        assertEq(_trove.collateral, _collateralNeeded, "E24");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E25");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E26");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E27");
        assertEq(_trove.owner, userBorrower, "E28");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E29");
        assertLt(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E30"); // increased debt --> lower CR

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
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E41");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E42");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * _newAnnualInterestRate, "E43");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E44");
        assertEq(troveManager.zombie_trove_id(), 0, "E45");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E46");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E47");
    }

    // 1. lend
    // 2. borrow half of available liquidity from 1st borrower
    // 3. borrow other half from 2nd borrower
    // 4. adjust rate of first borrower (no upfront fee)
    function test_adjustRate_changePlaceInList(uint256 _amount) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 2, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Half the amount for each borrower
        uint256 _borrowAmount = _amount / 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _borrowAmount + troveManager.get_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove from first borrower
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove from another borrower
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _collateralNeeded, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, userBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E7"); // 0.1%

        // Check another trove info
        _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _collateralNeeded, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, anotherUserBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E7"); // 0.1%

        // Make sure those change places after we adjust the rate of the first trove
        uint256 _firstBefore = _troveId;
        uint256 _lastBefore = _troveIdAnotherBorrower;

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E8");
        assertEq(sortedTroves.size(), 2, "E9");
        assertEq(sortedTroves.first(), _firstBefore, "E10");
        assertEq(sortedTroves.last(), _lastBefore, "E11");
        assertTrue(sortedTroves.contains(_troveId), "E12");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E13");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E14");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E15");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E16");
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E18");
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _borrowAmount, "E19");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E20");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E21");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E22");
        assertEq(troveManager.zombie_trove_id(), 0, "E23");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E24");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E25");

        // Skip time to be able to adjust the rate again without upfront fee
        skip(troveManager.INTEREST_RATE_ADJ_COOLDOWN());

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%
        vm.prank(anotherUserBorrower);
        troveManager.adjust_interest_rate(_troveIdAnotherBorrower, _newAnnualInterestRate, 0, 0, 0);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E26"); // did not touch this trove
        assertEq(_trove.collateral, _collateralNeeded, "E27");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E28");
        assertEq(_trove.last_debt_update_time, block.timestamp - troveManager.INTEREST_RATE_ADJ_COOLDOWN(), "E29");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp - troveManager.INTEREST_RATE_ADJ_COOLDOWN(), "E30");
        assertEq(_trove.owner, userBorrower, "E31");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E32");
        assertLt(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E33"); // increased debt --> lower CR

        // Calculate expected debt with interest accumulated
        uint256 _secondExpectedDebt = _expectedDebt + ((_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - _trove.last_debt_update_time)) / (365 days * 1e18));

        // Check another trove info
        _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _secondExpectedDebt, "E34");
        assertEq(_trove.collateral, _collateralNeeded, "E35");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E36");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E37");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E38");
        assertEq(_trove.owner, anotherUserBorrower, "E39");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E40");
        assertLt(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E41"); // increased debt --> lower CR

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E42");
        assertEq(sortedTroves.size(), 2, "E43");
        assertEq(sortedTroves.first(), _lastBefore, "E44"); // _changed place
        assertEq(sortedTroves.last(), _firstBefore, "E45"); // _changed place
        assertTrue(sortedTroves.contains(_troveId), "E46");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E47");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E48");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E49");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E50");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E51");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E52");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E53");

        // Add interest to `_expectedDebt`
        uint256 _expectedDebtWithInterest = _expectedDebt + ((_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - (block.timestamp - troveManager.INTEREST_RATE_ADJ_COOLDOWN()))) / (365 days * 1e18));

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), _expectedDebtWithInterest + _secondExpectedDebt, 1, "E54");
        assertEq(troveManager.total_weighted_debt(), (_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE) + (_secondExpectedDebt * _newAnnualInterestRate), "E55");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E56");
        assertEq(troveManager.zombie_trove_id(), 0, "E57");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E58");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E59");
    }

}
