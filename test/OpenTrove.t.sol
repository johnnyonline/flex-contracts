// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract OpenTroveTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // 1. lend
    // 2. borrow some (less than available liquidity)
    function test_openTrove(uint256 _lendAmount, uint256 _borrowAmount) public {
        _lendAmount = bound(_lendAmount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, troveManager.MIN_DEBT(), _lendAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

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
    }

    // 1. lend
    // 2. borrow more than available liquidity (should get all the liquidity)
    function test_openTrove_borrowMoreThanAvailableLiquidity(uint256 _lendAmount, uint256 _borrowAmount) public {
        _lendAmount = bound(_lendAmount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, _lendAmount, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _borrowAmount + troveManager.calculate_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache the available liquidity
        uint256 _availableLiquidity = borrowToken.balanceOf(address(lender));

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
        assertEq(borrowToken.balanceOf(userBorrower), _availableLiquidity, "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E19");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E20");
        assertEq(troveManager.zombie_trove_id(), 0, "E21");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E22");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E23");
    }

    // 1. lend
    // 2. 1st borrower borrows all
    // 3. 2nd borrower borrows slightly more (redeems 1st borrower completely, including upfront fee)
    function test_openTrove_borrowNoAvailableLiquidity_andRedeemAllDebt(uint256 _amount) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.calculate_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_expectedDebt * 1e18 / exchange.price());

        // Second amount is slightly more than the first amount, just enough to cover the upfront fee
        uint256 _secondAmount = _amount + troveManager.calculate_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondCollateralNeeded = _secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();
        uint256 _secondExpectedDebt = _secondAmount + troveManager.calculate_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove and redeem from the other borrower
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, 0, "E0");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, anotherUserBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E6");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E7");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E8");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E9");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E10");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E11");
        assertEq(_trove.owner, userBorrower, "E12");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E13");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E14"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E15");
        assertEq(sortedTroves.size(), 1, "E16");
        assertEq(sortedTroves.first(), _troveId, "E17");
        assertEq(sortedTroves.last(), _troveId, "E18");
        assertTrue(sortedTroves.contains(_troveId), "E19");
        assertFalse(sortedTroves.contains(_troveIdAnotherBorrower), "E20");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E21");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E22");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E23");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E24");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E25"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount, "E26");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E27");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E28");
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E29");
        assertEq(troveManager.zombie_trove_id(), 0, "E30");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E31");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E32");
    }

    // 1. lend
    // 2. 1st borrower borrows some
    // 3. 2nd borrower borrows rest + some (redeems 1st borrower (but leaves him above min debt) and takes all remaining liquidity)
    function test_openTrove_borrowSomeAvailableLiquidity_andBorrowTheRestAndRedeemSome(uint256 _amount) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 250 / 100, maxFuzzAmount); // Lend at least 2.5x min debt

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // First borrower borrows half the available liquidity
        uint256 _firstAmount = _amount / 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _firstAmount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure half of the liquidity was taken from the lender
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), _firstAmount, 2, "E0");

        // Second amount is slightly more than the first amount, not too much more though, to leave the first borrower above min debt
        uint256 _secondAmount = _firstAmount * 110 / 100; // 10% more
        _secondAmount += troveManager.calculate_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondCollateralNeeded = _secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();
        uint256 _secondExpectedDebt = _secondAmount + troveManager.calculate_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove and redeem from the other borrower
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected debt (borrow amount + upfront fee - redeemed debt)
        uint256 _expectedDebt = _amount - _secondAmount + troveManager.calculate_upfront_fee(_firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected collateral after redemption (only need to redeem the difference between the two amounts)
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - ((_secondAmount - _firstAmount) * 1e18 / exchange.price());

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E1");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, anotherUserBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E7");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E8");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E9");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E10");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E11");
        assertEq(_trove.owner, userBorrower, "E12");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E13");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E14"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E15");
        assertEq(sortedTroves.size(), 2, "E16");
        assertEq(sortedTroves.first(), _troveIdAnotherBorrower, "E17");
        assertEq(sortedTroves.last(), _troveId, "E18");
        assertTrue(sortedTroves.contains(_troveId), "E19");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E20");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E21");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E22");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E23");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E24");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E25"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount / 2, "E26");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E27");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E28");
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E29");
        assertEq(troveManager.zombie_trove_id(), 0, "E30");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E31");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E32");
    }

    // 1. lend
    // 2. 1st borrower borrows all
    // 3. 2nd borrower borrows less, but leaves 1st borrower with less than min debt (and more than 0), so it turns into a zombie
    function test_openTrove_borrowNoAvailableLiquidity_andRedeemSome(uint256 _amount, uint256 _secondAmount) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount); // Lend all
        _secondAmount = bound(_secondAmount, troveManager.MIN_DEBT(), _amount);

        // Calculate expected upfront fee for the first borrower
        uint256 _expectedUpfrontFee = troveManager.calculate_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Delta between the two amounts should be at most min debt minus upfront fee so that the 1st borrower ends up below min debt
        vm.assume(_amount - _secondAmount < troveManager.MIN_DEBT() - _expectedUpfrontFee);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Get the collateral price
        uint256 _collateralPrice = exchange.price();

        // Calculate target collateral ratio (10% above MCR)
        uint256 _targetCollateralRatio = troveManager.MINIMUM_COLLATERAL_RATIO() * 110 / 100;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * _targetCollateralRatio / _collateralPrice;

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _secondCollateralNeeded = _secondAmount * _targetCollateralRatio / _collateralPrice;

        // Open a trove that tries to redeem from the other borrower and revert because it would leave them below min debt (but above 0)
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected debt (borrow amount + upfront fee - redeemed debt)
        uint256 _expectedDebt = _amount - _secondAmount + troveManager.calculate_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected collateral after redemption (only need to redeem the difference between the two amounts)
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_secondAmount * 1e18 / exchange.price());

        // Calculate expected debt for the second borrower
        uint256 _secondExpectedDebt = _secondAmount + troveManager.calculate_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E1");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E0");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E1");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
        assertEq(_trove.owner, anotherUserBorrower, "E5");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E6");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E7");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E8");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E9");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E10");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E11");
        assertEq(_trove.owner, userBorrower, "E12");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E13");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E14"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E15");
        assertEq(sortedTroves.size(), 1, "E16");
        assertEq(sortedTroves.first(), _troveId, "E17");
        assertEq(sortedTroves.last(), _troveId, "E18");
        assertTrue(sortedTroves.contains(_troveId), "E19");
        assertFalse(sortedTroves.contains(_troveIdAnotherBorrower), "E20");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E21");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E22");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E23");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E24");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E25"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount, "E26");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E27");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E28");
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E29");
        assertEq(troveManager.zombie_trove_id(), _troveIdAnotherBorrower, "E30");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E31");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E32");
    }

    // ------- @todo

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
