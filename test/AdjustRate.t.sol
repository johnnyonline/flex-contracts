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
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E7"
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
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E16");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E19");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E20");
        assertEq(troveManager.zombie_trove_id(), 0, "E21");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E22");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E23");

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
        assertEq(_trove.debt, _secondExpectedDebt, "E24");
        assertEq(_trove.collateral, _collateralNeeded, "E25");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E26");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E27");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E28");
        assertEq(_trove.owner, userBorrower, "E29");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E30");
        assertGt(_trove.debt, _expectedDebt, "E31"); // debt increased due to interest

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E32");
        assertEq(sortedTroves.size(), 1, "E33");
        assertEq(sortedTroves.first(), _troveId, "E34");
        assertEq(sortedTroves.last(), _troveId, "E35");
        assertTrue(sortedTroves.contains(_troveId), "E36");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E37");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E38");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E39");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E40");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E41");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E42");

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), _secondExpectedDebt, 2, "E43");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * _newAnnualInterestRate, "E44");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E45");
        assertEq(troveManager.zombie_trove_id(), 0, "E46");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E47");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E48");
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
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E7"
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
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E16");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E19");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E20");
        assertEq(troveManager.zombie_trove_id(), 0, "E21");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E22");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E23");

        // Skip time but still be within the cooldown period
        skip(troveManager.interest_rate_adj_cooldown() / 2);

        // Double the interest rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%

        // Calculate second expected debt with interest accumulated
        uint256 _debtAfterInterest = troveManager.get_trove_debt_after_interest(_troveId);
        uint256 _secondExpectedDebt = _debtAfterInterest + troveManager.get_upfront_fee(_debtAfterInterest, _newAnnualInterestRate, true);

        // Finally adjust the rate
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, type(uint256).max);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E24");
        assertEq(_trove.collateral, _collateralNeeded, "E25");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E26");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E27");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E28");
        assertEq(_trove.owner, userBorrower, "E29");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E30");
        assertLt(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            "E31"
        ); // increased debt --> lower CR

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E32");
        assertEq(sortedTroves.size(), 1, "E33");
        assertEq(sortedTroves.first(), _troveId, "E34");
        assertEq(sortedTroves.last(), _troveId, "E35");
        assertTrue(sortedTroves.contains(_troveId), "E36");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E37");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E38");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E39");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E40");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E41");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E42");

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), _secondExpectedDebt, 2, "E43");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * _newAnnualInterestRate, "E44");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E45");
        assertEq(troveManager.zombie_trove_id(), 0, "E46");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E47");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E48");
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
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E7"
        ); // 0.1%

        // Check another trove info
        _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E8");
        assertEq(_trove.collateral, _collateralNeeded, "E9");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E10");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E11");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E12");
        assertEq(_trove.owner, anotherUserBorrower, "E13");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E14");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E15"
        ); // 0.1%

        // Make sure those change places after we adjust the rate of the first trove
        uint256 _firstBefore = _troveId;
        uint256 _lastBefore = _troveIdAnotherBorrower;

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E16");
        assertEq(sortedTroves.size(), 2, "E17");
        assertEq(sortedTroves.first(), _firstBefore, "E18");
        assertEq(sortedTroves.last(), _lastBefore, "E19");
        assertTrue(sortedTroves.contains(_troveId), "E20");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E21");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E22");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E23");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E24");
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E25");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E26");
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _borrowAmount, "E27");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E28");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E29");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E30");
        assertEq(troveManager.zombie_trove_id(), 0, "E31");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E32");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E33");

        // Skip time to be able to adjust the rate again without upfront fee
        skip(troveManager.interest_rate_adj_cooldown());

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%
        vm.prank(anotherUserBorrower);
        troveManager.adjust_interest_rate(_troveIdAnotherBorrower, _newAnnualInterestRate, 0, 0, 0);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E34"); // did not touch this trove
        assertEq(_trove.collateral, _collateralNeeded, "E35");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E36");
        assertEq(_trove.last_debt_update_time, block.timestamp - troveManager.interest_rate_adj_cooldown(), "E37");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp - troveManager.interest_rate_adj_cooldown(), "E38");
        assertEq(_trove.owner, userBorrower, "E39");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E40");
        assertGt(troveManager.get_trove_debt_after_interest(_troveId), _expectedDebt, "E41"); // debt increased due to interest

        // Calculate expected debt with interest accumulated
        uint256 _secondExpectedDebt = _expectedDebt
            + ((_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - _trove.last_debt_update_time))
                / (365 days * BORROW_TOKEN_PRECISION));

        // Check another trove info
        _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _secondExpectedDebt, "E42");
        assertEq(_trove.collateral, _collateralNeeded, "E43");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E44");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E45");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E46");
        assertEq(_trove.owner, anotherUserBorrower, "E47");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E48");
        assertGt(_trove.debt, _expectedDebt, "E49"); // debt increased due to interest

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E50");
        assertEq(sortedTroves.size(), 2, "E51");
        assertEq(sortedTroves.first(), _lastBefore, "E52"); // _changed place
        assertEq(sortedTroves.last(), _firstBefore, "E53"); // _changed place
        assertTrue(sortedTroves.contains(_troveId), "E54");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E55");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E56");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E57");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E58");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E59");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E60");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E61");

        // Add interest to `_expectedDebt`
        uint256 _expectedDebtWithInterest = _expectedDebt
            + ((_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - (block.timestamp - troveManager.interest_rate_adj_cooldown())))
                / (365 days * BORROW_TOKEN_PRECISION));

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), _expectedDebtWithInterest + _secondExpectedDebt, 3, "E62");
        assertEq(
            troveManager.total_weighted_debt(), (_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE) + (_secondExpectedDebt * _newAnnualInterestRate), "E63"
        );
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E64");
        assertEq(troveManager.zombie_trove_id(), 0, "E65");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E66");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E67");
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
                * 998 / 1000;

        // Open a trove at max rate so the upfront fee on premature adjustment is large
        uint256 _rate = troveManager.min_annual_interest_rate() * 20;
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _maxBorrowableAtMCR, _rate);

        // Adjust to a different rate to trigger the premature adjustment fee
        uint256 _newAnnualInterestRate = _rate - 1;

        vm.prank(userBorrower);
        vm.expectRevert("!minimum_collateral_ratio");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, type(uint256).max);
    }

    function test_adjustRate_approvedOperator(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Approve operator
        vm.prank(userBorrower);
        troveManager.approve(operator, true);

        // Skip past cooldown
        skip(troveManager.interest_rate_adj_cooldown() + 1);

        // Operator adjusts rate
        uint256 _newRate = DEFAULT_ANNUAL_INTEREST_RATE * 2;
        vm.prank(operator);
        troveManager.adjust_interest_rate(_troveId, _newRate, 0, 0, type(uint256).max);

        assertEq(troveManager.troves(_troveId).annual_interest_rate, _newRate, "E0");
    }

    function test_adjustRate_unapprovedOperator_reverts(
        uint256 _amount,
        address _caller
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);
        vm.assume(_caller != userBorrower);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        vm.prank(_caller);
        vm.expectRevert("!owner");
        troveManager.adjust_interest_rate(_troveId, DEFAULT_ANNUAL_INTEREST_RATE * 2, 0, 0, type(uint256).max);
    }

}
