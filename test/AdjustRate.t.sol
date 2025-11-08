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
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _amount = troveManager.MIN_DEBT();

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

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
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E8"
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

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E24");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E25");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E26");

        // Skip time to be able to adjust the rate again without upfront fee
        skip(troveManager.INTEREST_RATE_ADJ_COOLDOWN());

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);

        // Check everything again

        // Calculate expected debt with interest accumulated
        uint256 _secondExpectedDebt = troveManager.get_trove_debt_after_interest(_troveId);

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E27");
        assertEq(_trove.collateral, _collateralNeeded, "E28");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E29");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E31");
        assertEq(_trove.owner, userBorrower, "E32");
        assertEq(_trove.pending_owner, address(0), "E33");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E34");
        assertLt(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E35"); // increased debt --> lower CR

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E36");
        assertEq(sortedTroves.size(), 1, "E37");
        assertEq(sortedTroves.first(), _troveId, "E38");
        assertEq(sortedTroves.last(), _troveId, "E39");
        assertTrue(sortedTroves.contains(_troveId), "E40");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E41");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E42");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E43");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E44");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E45");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E46");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E47");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * _newAnnualInterestRate, "E48");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E49");
        assertEq(troveManager.zombie_trove_id(), 0, "E50");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E51");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E52");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E53");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E54");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip only half of the rate cooldown period and adjust rate prematurely (with upfront fee)
    function test_adjustRate_prematurely(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

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
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E8"
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

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E24");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E25");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E26");

        // Skip time but still be within the cooldown period
        skip(troveManager.INTEREST_RATE_ADJ_COOLDOWN() / 2);

        // Double the interest rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%

        // Calculate second expected debt with interest accumulated
        uint256 _interestOnFirstDebt = _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE
            * (block.timestamp - _trove.last_debt_update_time) / (365 days * 1e18);
        uint256 _secondExpectedDebt = troveManager.get_trove_debt_after_interest(_troveId)
            + troveManager.get_upfront_fee(_expectedDebt + _interestOnFirstDebt, _newAnnualInterestRate);

        // Finally adjust the rate
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, type(uint256).max);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E27");
        assertEq(_trove.collateral, _collateralNeeded, "E28");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E29");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E31");
        assertEq(_trove.owner, userBorrower, "E32");
        assertEq(_trove.pending_owner, address(0), "E33");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E34");
        assertLt(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E35"); // increased debt --> lower CR

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E36");
        assertEq(sortedTroves.size(), 1, "E37");
        assertEq(sortedTroves.first(), _troveId, "E38");
        assertEq(sortedTroves.last(), _troveId, "E39");
        assertTrue(sortedTroves.contains(_troveId), "E40");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E41");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E42");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E43");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E44");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E45");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E46");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E47");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * _newAnnualInterestRate, "E48");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E49");
        assertEq(troveManager.zombie_trove_id(), 0, "E50");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E51");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E52");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E53");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E54");
    }

    // 1. lend
    // 2. borrow half of available liquidity from 1st borrower
    // 3. borrow other half from 2nd borrower
    // 4. adjust rate of first borrower (no upfront fee)
    function test_adjustRate_changePlaceInList(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 2, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Half the amount for each borrower
        uint256 _borrowAmount = _amount / 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt =
            _borrowAmount + troveManager.get_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove from first borrower
        uint256 _troveId =
            mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove from another borrower
        uint256 _troveIdAnotherBorrower =
            mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

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
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E8"
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
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E17"
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

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E34");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E35");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E36");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E37");

        // Skip time to be able to adjust the rate again without upfront fee
        skip(troveManager.INTEREST_RATE_ADJ_COOLDOWN());

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%
        vm.prank(anotherUserBorrower);
        troveManager.adjust_interest_rate(_troveIdAnotherBorrower, _newAnnualInterestRate, 0, 0, 0);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E38"); // did not touch this trove
        assertEq(_trove.collateral, _collateralNeeded, "E39");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E40");
        assertEq(_trove.last_debt_update_time, block.timestamp - troveManager.INTEREST_RATE_ADJ_COOLDOWN(), "E41");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp - troveManager.INTEREST_RATE_ADJ_COOLDOWN(), "E42");
        assertEq(_trove.owner, userBorrower, "E43");
        assertEq(_trove.pending_owner, address(0), "E44");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E45");
        assertLt(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E46"); // increased debt --> lower CR

        // Calculate expected debt with interest accumulated
        uint256 _secondExpectedDebt = _expectedDebt
            + ((_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * (block.timestamp - _trove.last_debt_update_time))
                / (365 days * 1e18));

        // Check another trove info
        _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _secondExpectedDebt, "E47");
        assertEq(_trove.collateral, _collateralNeeded, "E48");
        assertEq(_trove.annual_interest_rate, _newAnnualInterestRate, "E49");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E50");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E51");
        assertEq(_trove.owner, anotherUserBorrower, "E52");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E53");
        assertLt(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E54"); // increased debt --> lower CR

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E55");
        assertEq(sortedTroves.size(), 2, "E56");
        assertEq(sortedTroves.first(), _lastBefore, "E57"); // _changed place
        assertEq(sortedTroves.last(), _firstBefore, "E58"); // _changed place
        assertTrue(sortedTroves.contains(_troveId), "E59");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E60");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E61");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E62");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E63");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E64");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E65");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E66");

        // Add interest to `_expectedDebt`
        uint256 _expectedDebtWithInterest = _expectedDebt
            + ((_expectedDebt
                    * DEFAULT_ANNUAL_INTEREST_RATE
                    * (block.timestamp - (block.timestamp - troveManager.INTEREST_RATE_ADJ_COOLDOWN())))
                / (365 days * 1e18));

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), _expectedDebtWithInterest + _secondExpectedDebt, 1, "E67");
        assertEq(
            troveManager.total_weighted_debt(),
            (_expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE) + (_secondExpectedDebt * _newAnnualInterestRate),
            "E68"
        );
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E69");
        assertEq(troveManager.zombie_trove_id(), 0, "E70");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E71");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E72");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E73");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E74");
    }

    function test_adjustRate_rateTooLow(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = troveManager.MIN_ANNUAL_INTEREST_RATE() - 1; // below minimum

        vm.prank(userBorrower);
        vm.expectRevert("!MIN_ANNUAL_INTEREST_RATE");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);
    }

    function test_adjustRate_rateTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally adjust the rate
        uint256 _newAnnualInterestRate = troveManager.MAX_ANNUAL_INTEREST_RATE() + 1; // above maximum

        vm.prank(userBorrower);
        vm.expectRevert("!MAX_ANNUAL_INTEREST_RATE");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);
    }

    function test_adjustRate_notOwner(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

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
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Pull enough liquidity to make trove a zombie trove (but above 0 debt)
        uint256 _amountToPull = _amount - 100 ether;

        // Pull liquidity from lender to make trove a zombie trove (but above 0 debt)
        vm.prank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);

        // Make sure trove is a zombie trove
        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.zombie), "E25");

        // Try to adjust the rate of a non-active trove
        uint256 _newAnnualInterestRate = DEFAULT_ANNUAL_INTEREST_RATE * 2; // 2%
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, 0);
    }

    function test_adjustRate_sameRate(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

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
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate the maximum borrowable amount that would leave the trove at MCR
        uint256 _maxBorrowableAtMCR =
            (_collateralNeeded * priceOracle.price() / troveManager.MINIMUM_COLLATERAL_RATIO()) * 995 / 1000;

        // Open a trove
        uint256 _troveId =
            mintAndOpenTrove(userBorrower, _collateralNeeded, _maxBorrowableAtMCR, DEFAULT_ANNUAL_INTEREST_RATE);

        // Use max annual interest rate to increase the debt as much as possible
        uint256 _newAnnualInterestRate = troveManager.MAX_ANNUAL_INTEREST_RATE(); // max rate

        vm.prank(userBorrower);
        vm.expectRevert("!MINIMUM_COLLATERAL_RATIO");
        troveManager.adjust_interest_rate(_troveId, _newAnnualInterestRate, 0, 0, type(uint256).max);
    }

}
