// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract OpenTroveTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // 1. lend
    // 2. borrow some (less than available liquidity)
    function test_openTrove(
        uint256 _lendAmount,
        uint256 _borrowAmount
    ) public {
        _lendAmount = bound(_lendAmount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, troveManager.MIN_DEBT(), _lendAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

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
        assertEq(borrowToken.balanceOf(address(lender)), _lendAmount - _borrowAmount, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E18");

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
    }

    // 1. lend
    // 2. borrow more than available liquidity (should get all the liquidity)
    function test_openTrove_borrowMoreThanAvailableLiquidity(
        uint256 _lendAmount,
        uint256 _borrowAmount
    ) public {
        _lendAmount = bound(_lendAmount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, _lendAmount, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt =
            _borrowAmount + troveManager.get_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache the available liquidity
        uint256 _availableLiquidity = borrowToken.balanceOf(address(lender));

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
        assertEq(borrowToken.balanceOf(userBorrower), _availableLiquidity, "E18");

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
    }

    // 1. lend
    // 2. 1st borrower borrows all
    // 3. 2nd borrower borrows slightly more (redeems 1st borrower completely, including upfront fee)
    function test_openTrove_borrowNoAvailableLiquidity_andRedeemAllDebt(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower =
            mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_expectedDebt * 1e18 / priceOracle.price());

        // Second amount is slightly more than the first amount, just enough to cover the upfront fee
        uint256 _secondAmount = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondCollateralNeeded = _secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();
        uint256 _secondExpectedDebt =
            _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove and redeem from the other borrower
        uint256 _troveId =
            mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, 0, "E1");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E2");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E3");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E4");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E5");
        assertEq(_trove.owner, anotherUserBorrower, "E6");
        assertEq(_trove.pending_owner, address(0), "E7");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E8");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E9");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E10");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E11");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E12");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E13");
        assertEq(_trove.owner, userBorrower, "E14");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E15");
        assertApproxEqRel(
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E16"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E17");
        assertEq(sortedTroves.size(), 1, "E18");
        assertEq(sortedTroves.first(), _troveId, "E19");
        assertEq(sortedTroves.last(), _troveId, "E20");
        assertTrue(sortedTroves.contains(_troveId), "E21");
        assertFalse(sortedTroves.contains(_troveIdAnotherBorrower), "E22");

        // Check balances
        assertEq(
            collateralToken.balanceOf(address(troveManager)),
            _secondCollateralNeeded + _expectedCollateralAfterRedemption,
            "E23"
        );
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E24");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E25");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E26");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E27"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount, "E28");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E29");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E30");
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E31");
        assertEq(troveManager.zombie_trove_id(), 0, "E32");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E33");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E34");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E35");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E36");
    }

    // 1. lend
    // 2. 1st borrower borrows some
    // 3. 2nd borrower borrows rest + some (redeems 1st borrower (but leaves him above min debt) and takes all remaining liquidity)
    function test_openTrove_borrowSomeAvailableLiquidity_andBorrowTheRestAndRedeemSome(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 250 / 100, maxFuzzAmount); // Lend at least 2.5x min debt

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // First borrower borrows half the available liquidity
        uint256 _firstAmount = _amount / 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _firstAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower =
            mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure half of the liquidity was taken from the lender
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), _firstAmount, 2, "E0");

        // Second amount is slightly more than the first amount, not too much more though, to leave the first borrower above min debt
        uint256 _secondAmount = _firstAmount * 110 / 100; // 10% more
        _secondAmount += troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondCollateralNeeded = _secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();
        uint256 _secondExpectedDebt =
            _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove and redeem from the other borrower
        uint256 _troveId =
            mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected debt (borrow amount + upfront fee - redeemed debt)
        uint256 _expectedDebt =
            _amount - _secondAmount + troveManager.get_upfront_fee(_firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected collateral after redemption (only need to redeem the difference between the two amounts)
        uint256 _expectedCollateralAfterRedemption =
            _collateralNeeded - ((_secondAmount - _firstAmount) * 1e18 / priceOracle.price());

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E1");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E2");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E3");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E4");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E5");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E6");
        assertEq(_trove.owner, anotherUserBorrower, "E7");
        assertEq(_trove.pending_owner, address(0), "E8");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E9");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E10");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E11");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E12");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E13");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E14");
        assertEq(_trove.owner, userBorrower, "E15");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E16");
        assertApproxEqRel(
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E17"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E18");
        assertEq(sortedTroves.size(), 2, "E19");
        assertEq(sortedTroves.first(), _troveIdAnotherBorrower, "E20");
        assertEq(sortedTroves.last(), _troveId, "E21");
        assertTrue(sortedTroves.contains(_troveId), "E22");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E23");

        // Check balances
        assertEq(
            collateralToken.balanceOf(address(troveManager)),
            _secondCollateralNeeded + _expectedCollateralAfterRedemption,
            "E24"
        );
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E25");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E26");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E27");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E28"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount / 2, "E29");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E30");
        assertEq(
            troveManager.total_weighted_debt(),
            _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE,
            "E31"
        );
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E32");
        assertEq(troveManager.zombie_trove_id(), 0, "E33");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E34");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E35");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E36");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E37");
    }

    // 1. lend
    // 2. 1st borrower borrows all
    // 3. 2nd borrower borrows less, but leaves 1st borrower with less than min debt (and more than 0), so it turns into a zombie
    function test_openTrove_borrowNoAvailableLiquidity_andRedeemSome(
        uint256 _amount,
        uint256 _secondAmount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount); // Lend all
        _secondAmount = bound(_secondAmount, troveManager.MIN_DEBT(), _amount);

        // Calculate expected upfront fee for the first borrower
        uint256 _expectedUpfrontFee = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Delta between the two amounts should be at most min debt minus upfront fee so that the 1st borrower ends up below min debt
        vm.assume(_amount - _secondAmount < troveManager.MIN_DEBT() - _expectedUpfrontFee);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Get the collateral price
        uint256 _collateralPrice = priceOracle.price();

        // Calculate target collateral ratio (10% above MCR)
        uint256 _targetCollateralRatio = troveManager.MINIMUM_COLLATERAL_RATIO() * 110 / 100;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * _targetCollateralRatio / _collateralPrice;

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower =
            mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _secondCollateralNeeded = _secondAmount * _targetCollateralRatio / _collateralPrice;

        // Open a trove that tries to redeem from the other borrower and revert because it would leave them below min debt (but above 0)
        uint256 _troveId =
            mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected debt (borrow amount + upfront fee - redeemed debt)
        uint256 _expectedDebt =
            _amount - _secondAmount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected collateral after redemption (only need to redeem the difference between the two amounts)
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_secondAmount * 1e18 / priceOracle.price());

        // Calculate expected debt for the second borrower
        uint256 _secondExpectedDebt =
            _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E1");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E2");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E3");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E4");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E5");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E6");
        assertEq(_trove.owner, anotherUserBorrower, "E7");
        assertEq(_trove.pending_owner, address(0), "E8");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E9");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E10");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E11");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E12");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E13");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E14");
        assertEq(_trove.owner, userBorrower, "E15");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E16");
        assertApproxEqRel(
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E17"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E18");
        assertEq(sortedTroves.size(), 1, "E19");
        assertEq(sortedTroves.first(), _troveId, "E20");
        assertEq(sortedTroves.last(), _troveId, "E21");
        assertTrue(sortedTroves.contains(_troveId), "E22");
        assertFalse(sortedTroves.contains(_troveIdAnotherBorrower), "E23");

        // Check balances
        assertEq(
            collateralToken.balanceOf(address(troveManager)),
            _secondCollateralNeeded + _expectedCollateralAfterRedemption,
            "E24"
        );
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E25");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E26");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E27");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E28"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount, "E29");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E30");
        assertEq(
            troveManager.total_weighted_debt(),
            _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE,
            "E31"
        );
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E32");
        assertEq(troveManager.zombie_trove_id(), _troveIdAnotherBorrower, "E33");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E34");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E35");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E36");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E37");
    }

    // 1. lend
    // 2. 1st borrower borrows all
    // 3. 2nd borrower borrows slightly more (redeems 1st borrower completely, including upfront fee) using new exchange route
    function test_openTrove_usingNewExchangeRoute(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower =
            mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_expectedDebt * 1e18 / priceOracle.price());

        // Second amount is slightly more than the first amount, just enough to cover the upfront fee
        uint256 _secondAmount = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondCollateralNeeded = _secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();
        uint256 _secondExpectedDebt =
            _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Airdrop some collateral to borrower
        airdrop(address(collateralToken), userBorrower, _secondCollateralNeeded);

        // Open a trove and redeem from the other borrower using new exchange route
        vm.startPrank(userBorrower);
        collateralToken.approve(address(troveManager), _secondCollateralNeeded);
        vm.expectRevert("!route");
        troveManager.open_trove(
            block.timestamp, // owner_index
            _secondCollateralNeeded, // collateral_amount
            _secondAmount, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            1, // route_index
            0 // min_debt_out
        );
        vm.stopPrank();

        // Add new exchange route
        vm.prank(deployer);
        exchange.add_route(address(exchangeRoute));

        vm.prank(userBorrower);
        uint256 _troveId = troveManager.open_trove(
            block.timestamp, // owner_index
            _secondCollateralNeeded, // collateral_amount
            _secondAmount, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            1, // route_index
            0 // min_debt_out
        );

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, 0, "E1");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E2");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E3");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E4");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E5");
        assertEq(_trove.owner, anotherUserBorrower, "E6");
        assertEq(_trove.pending_owner, address(0), "E7");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E8");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E9");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E10");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E11");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E12");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E13");
        assertEq(_trove.owner, userBorrower, "E14");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E15");
        assertApproxEqRel(
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E16"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E17");
        assertEq(sortedTroves.size(), 1, "E18");
        assertEq(sortedTroves.first(), _troveId, "E19");
        assertEq(sortedTroves.last(), _troveId, "E20");
        assertTrue(sortedTroves.contains(_troveId), "E21");
        assertFalse(sortedTroves.contains(_troveIdAnotherBorrower), "E22");

        // Check balances
        assertEq(
            collateralToken.balanceOf(address(troveManager)),
            _secondCollateralNeeded + _expectedCollateralAfterRedemption,
            "E23"
        );
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E24");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E25");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E26");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E27"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount, "E28");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E29");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E30");
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E31");
        assertEq(troveManager.zombie_trove_id(), 0, "E32");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E33");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E34");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E35");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E36");
    }

    function test_openTrove_zeroCollateral() public {
        vm.prank(userBorrower);
        vm.expectRevert("!collateral_amount");
        troveManager.open_trove(
            block.timestamp, // owner_index
            0, // collateral_amount
            1, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_openTrove_zeroDebt() public {
        vm.prank(userBorrower);
        vm.expectRevert("!debt_amount");
        troveManager.open_trove(
            block.timestamp, // owner_index
            1, // collateral_amount
            0, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_openTrove_rateTooLow(
        uint256 _tooLowRate
    ) public {
        _tooLowRate = bound(_tooLowRate, 0, troveManager.MIN_ANNUAL_INTEREST_RATE() - 1);
        vm.prank(userBorrower);
        vm.expectRevert("!MIN_ANNUAL_INTEREST_RATE");
        troveManager.open_trove(
            block.timestamp, // owner_index
            1, // collateral_amount
            1, // debt_amount
            0, // upper_hint
            0, // lower_hint
            _tooLowRate, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_openTrove_rateTooHigh(
        uint256 _tooHighRate
    ) public {
        _tooHighRate = bound(_tooHighRate, troveManager.MAX_ANNUAL_INTEREST_RATE() + 1, maxFuzzAmount);
        vm.prank(userBorrower);
        vm.expectRevert("!MAX_ANNUAL_INTEREST_RATE");
        troveManager.open_trove(
            block.timestamp, // owner_index
            1, // collateral_amount
            1, // debt_amount
            0, // upper_hint
            0, // lower_hint
            _tooHighRate, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_openTrove_troveExists(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        vm.prank(userBorrower);
        vm.expectRevert("!empty");
        troveManager.open_trove(
            block.timestamp, // owner_index
            1, // collateral_amount
            1, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_openTrove_upfrontFeeTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        uint256 _upfrontFee = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        vm.prank(userBorrower);
        vm.expectRevert("!max_upfront_fee");
        troveManager.open_trove(
            block.timestamp, // owner_index
            _collateralNeeded, // collateral_amount
            _amount, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            _upfrontFee - 1, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_openTrove_debtTooLow() public {
        vm.prank(userBorrower);
        vm.expectRevert("!MIN_DEBT");
        troveManager.open_trove(
            block.timestamp, // owner_index
            1, // collateral_amount
            1, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_openTrove_belowMCR(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * (troveManager.MINIMUM_COLLATERAL_RATIO() - 1) / priceOracle.price();

        vm.prank(userBorrower);
        vm.expectRevert("!MINIMUM_COLLATERAL_RATIO");
        troveManager.open_trove(
            block.timestamp, // owner_index
            _collateralNeeded, // collateral_amount
            _amount, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_openTrove_notEnoughDebtOut(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Airdrop some collateral to borrower
        airdrop(address(collateralToken), userBorrower, _collateralNeeded);

        // Try to open a trove with max debt out
        vm.startPrank(userBorrower);
        collateralToken.approve(address(troveManager), _collateralNeeded);
        vm.expectRevert("shrekt");
        troveManager.open_trove(
            block.timestamp, // owner_index
            _collateralNeeded, // collateral_amount
            _amount, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0, // route_index
            type(uint256).max // min_debt_out
        );
        vm.stopPrank();
    }

}
