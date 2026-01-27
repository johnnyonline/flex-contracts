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
    function test_adjustRate(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
        assertEq(_trove.pending_owner, address(0), "E6");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E8"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E9");
        assertEq(sortedTroves.size(), 1, "E10");
        assertEq(sortedTroves.first(), _troveId, "E11");
        assertEq(sortedTroves.last(), _troveId, "E12");
        assertTrue(sortedTroves.contains(_troveId), "E13");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E14");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E15");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E16");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

        // Skip time to be able to adjust the rate again without upfront fee
        skip(troveManager.interest_rate_adj_cooldown());

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);

        // Check everything again

        // Calculate expected debt with interest accumulated
        uint256 _secondExpectedDebt = troveManager.get_trove_debt_after_interest(_troveId);

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E25");
        assertEq(_trove.collateral, _collateralNeeded, "E26");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E27");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E28");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E29");
        assertEq(_trove.owner, userBorrower, "E30");
        assertEq(_trove.pending_owner, address(0), "E31");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E32");
        assertLt(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            "E33"
        ); // increased debt --> lower CR

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E34");
        assertEq(sortedTroves.size(), 1, "E35");
        assertEq(sortedTroves.first(), _troveId, "E36");
        assertEq(sortedTroves.last(), _troveId, "E37");
        assertTrue(sortedTroves.contains(_troveId), "E38");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E39");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E40");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E41");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E42");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E43");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E44");

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), _secondExpectedDebt, 2, "E45");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * _newAnnualInterestRate, "E46");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E47");
        assertEq(troveManager.zombie_trove_id(), 0, "E48");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E49");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E50");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip only half of the rate cooldown period and adjust rate prematurely (with upfront fee)
    function test_adjustRate_prematurely(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
        assertEq(_trove.pending_owner, address(0), "E6");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E8"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E9");
        assertEq(sortedTroves.size(), 1, "E10");
        assertEq(sortedTroves.first(), _troveId, "E11");
        assertEq(sortedTroves.last(), _troveId, "E12");
        assertTrue(sortedTroves.contains(_troveId), "E13");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E14");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E15");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E16");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

        // Skip time but still be within the cooldown period
        skip(troveManager.interest_rate_adj_cooldown() / 2);

        // Double the interest rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%

        // Calculate second expected debt with interest accumulated
        uint256 _interestOnFirstDebt =
            _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - _trove.last_debt_update_time) / (365 days * BORROW_TOKEN_PRECISION);
        uint256 _secondExpectedDebt = troveManager.get_trove_debt_after_interest(_troveId)
            + troveManager.get_upfront_fee(_expectedDebt + _interestOnFirstDebt, _newAnnualInterestRate);

        // Finally adjust the rate
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, type(uint256).max);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E25");
        assertEq(_trove.collateral, _collateralNeeded, "E26");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E27");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E28");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E29");
        assertEq(_trove.owner, userBorrower, "E30");
        assertEq(_trove.pending_owner, address(0), "E31");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E32");
        assertLt(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            "E33"
        ); // increased debt --> lower CR

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E34");
        assertEq(sortedTroves.size(), 1, "E35");
        assertEq(sortedTroves.first(), _troveId, "E36");
        assertEq(sortedTroves.last(), _troveId, "E37");
        assertTrue(sortedTroves.contains(_troveId), "E38");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E39");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E40");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E41");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E42");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E43");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E44");

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), _secondExpectedDebt, 2, "E45");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * _newAnnualInterestRate, "E46");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E47");
        assertEq(troveManager.zombie_trove_id(), 0, "E48");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E49");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E50");
    }

    // 1. lend
    // 2. borrow half of available liquidity from 1st borrower
    // 3. borrow other half from 2nd borrower
    // 4. adjust rate of first borrower (no upfront fee)
    function test_adjustRate_changePlaceInList(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Half the amount for each borrower
        uint256 _borrowAmount = _amount / 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
        assertEq(_trove.pending_owner, address(0), "E6");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E8"
        ); // 0.1%

        // Check another trove info
        _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E9");
        assertEq(_trove.collateral, _collateralNeeded, "E10");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E11");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E12");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E13");
        assertEq(_trove.owner, anotherUserBorrower, "E14");
        assertEq(_trove.pending_owner, address(0), "E15");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E16");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E17"
        ); // 0.1%

        // Make sure those change places after we adjust the rate of the first trove
        uint256 _firstBefore = _troveId;
        uint256 _lastBefore = _troveIdAnotherBorrower;

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E18");
        assertEq(sortedTroves.size(), 2, "E19");
        assertEq(sortedTroves.first(), _firstBefore, "E20");
        assertEq(sortedTroves.last(), _lastBefore, "E21");
        assertTrue(sortedTroves.contains(_troveId), "E22");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E23");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E24");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E25");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E26");
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E27");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E28");
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _borrowAmount, "E29");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E30");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E31");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E32");
        assertEq(troveManager.zombie_trove_id(), 0, "E33");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E34");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E35");

        // Skip time to be able to adjust the rate again without upfront fee
        skip(troveManager.interest_rate_adj_cooldown());

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%
        vm.prank(anotherUserBorrower);
        troveManager.adjust_interest_rate(_troveIdAnotherBorrower, _newAnnualInterestRate, 0, 0, 0);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E36"); // did not touch this trove
        assertEq(_trove.collateral, _collateralNeeded, "E37");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E38");
        assertEq(_trove.last_debt_update_time, block.timestamp - troveManager.interest_rate_adj_cooldown(), "E39");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp - troveManager.interest_rate_adj_cooldown(), "E40");
        assertEq(_trove.owner, userBorrower, "E41");
        assertEq(_trove.pending_owner, address(0), "E42");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E43");
        assertLt(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            "E44"
        ); // increased debt --> lower CR

        // Calculate expected debt with interest accumulated
        uint256 _secondExpectedDebt = _expectedDebt
            + ((_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - _trove.last_debt_update_time))
                / (365 days * BORROW_TOKEN_PRECISION));

        // Check another trove info
        _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _secondExpectedDebt, "E45");
        assertEq(_trove.collateral, _collateralNeeded, "E46");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E47");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E48");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E49");
        assertEq(_trove.owner, anotherUserBorrower, "E50");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E51");
        assertLt(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            "E52"
        ); // increased debt --> lower CR

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E53");
        assertEq(sortedTroves.size(), 2, "E54");
        assertEq(sortedTroves.first(), _lastBefore, "E55"); // _changed place
        assertEq(sortedTroves.last(), _firstBefore, "E56"); // _changed place
        assertTrue(sortedTroves.contains(_troveId), "E57");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E58");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E59");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E60");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E61");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E62");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E63");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E64");

        // Add interest to `_expectedDebt`
        uint256 _expectedDebtWithInterest = _expectedDebt
            + ((_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - (block.timestamp - troveManager.interest_rate_adj_cooldown())))
                / (365 days * BORROW_TOKEN_PRECISION));

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), _expectedDebtWithInterest + _secondExpectedDebt, 3, "E65");
        assertEq(
            troveManager.total_weighted_debt(), (_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE) + (_secondExpectedDebt * _newAnnualInterestRate), "E66"
        );
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E67");
        assertEq(troveManager.zombie_trove_id(), 0, "E68");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E69");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E70");
    }

    function test_adjustRate_rateTooLow(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = troveManager.min_annual_interest_rate() - 1; // below minimum

        vm.prank(userBorrower);
        vm.expectRevert("!min_annual_interest_rate");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);
    }

    function test_adjustRate_rateTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = troveManager.max_annual_interest_rate() + 1; // above maximum

        vm.prank(userBorrower);
        vm.expectRevert("!max_annual_interest_rate");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);
    }

    function test_adjustRate_notOwner(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%

        vm.prank(anotherUserBorrower);
        vm.expectRevert("!owner");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);
    }

    function test_adjustRate_notActive(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Pull enough liquidity to make trove a zombie trove (but above 0 debt)
        uint256 _amountToPull = _amount - 100 * BORROW_TOKEN_PRECISION;

        // Pull liquidity from lender to make trove a zombie trove (but above 0 debt)
        vm.prank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);

        // Make sure trove is a zombie trove
        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.zombie), "E0");

        // Try to adjust the rate of a non-active trove
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);
    }

    function test_adjustRate_sameRate(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE; // same as current

        vm.prank(userBorrower);
        vm.expectRevert("!new_annual_interest_rate");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);
    }

    function test_adjustRate_belowMCR(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Calculate the maximum borrowable amount that would leave the trove at MCR
        uint256 _maxBorrowableAtMCR =
            ((_collateralNeeded * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / troveManager.minimum_collateral_ratio())
                * 995 / 1000;

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _maxBorrowableAtMCR, DEFAULT_ANNUAL_INTEREST_RATE);

        // Use max annual interest rate to increase the debt as much as possible
        uint256 _newAnnualInterestRate = troveManager.max_annual_interest_rate(); // max rate

        vm.prank(userBorrower);
        vm.expectRevert("!minimum_collateral_ratio");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, type(uint256).max);
    }

}
