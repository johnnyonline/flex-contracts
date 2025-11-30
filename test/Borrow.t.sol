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
        uint256 _collateralNeeded = _totalBorrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _borrowAmount + troveManager.get_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

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
        assertEq(_trove.pending_owner, address(0), "E6");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO * 2, 1e15, "E8"); // 0.1%

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
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E24");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E25");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E26");

        // Finally borrow more from the trove
        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _borrowAmount,
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt * 2, "E27");
        assertEq(_trove.collateral, _collateralNeeded, "E28");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E29");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E31");
        assertEq(_trove.owner, userBorrower, "E32");
        assertEq(_trove.pending_owner, address(0), "E33");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E34");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E35"); // 0.1%

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
        assertEq(borrowToken.balanceOf(userBorrower), _totalBorrowAmount, "E46");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E47");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E48");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E49");
        assertEq(troveManager.zombie_trove_id(), 0, "E50");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E51");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E52");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E53");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E54");
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
        uint256 _collateralNeeded = (_borrowAmount + troveManager.MIN_DEBT()) * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = troveManager.MIN_DEBT() + troveManager.get_upfront_fee(troveManager.MIN_DEBT(), DEFAULT_ANNUAL_INTEREST_RATE);

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
        assertEq(_trove.pending_owner, address(0), "E6");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
        assertGt(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E8");

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
        assertEq(borrowToken.balanceOf(address(lender)), _lendAmount - troveManager.MIN_DEBT(), "E17");
        assertEq(borrowToken.balanceOf(userBorrower), troveManager.MIN_DEBT(), "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E24");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E25");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E26");

        // Calculate expected debt after second borrow
        uint256 _secondExpectedDebt = _expectedDebt + _borrowAmount + troveManager.get_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally borrow more from the trove
        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _borrowAmount,
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E27");
        assertEq(_trove.collateral, _collateralNeeded, "E28");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E29");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E31");
        assertEq(_trove.owner, userBorrower, "E32");
        assertEq(_trove.pending_owner, address(0), "E33");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E34");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E35"); // 0.1%

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
        assertEq(borrowToken.balanceOf(userBorrower), _lendAmount, "E46");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E47");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E48");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E49");
        assertEq(troveManager.zombie_trove_id(), 0, "E50");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E51");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E52");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E53");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E54");
    }

    // 1. lend
    // 2. 1st borrow opens trove with half available liquidity
    // 3. 2nd borrow the other half of available liquidity
    // 4. 2nd borrower borrows again from trove and redeems the 1st borrower completely (using new exchange route)
    function test_borrowFromActiveTrove_redeemAnotherBorrower_useNewExchangeRoute(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 2, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Cut in half so we can borrow twice
        uint256 _halfAmount = _amount / 2;

        // Calculate how much collateral is needed for the half borrow amount
        uint256 _collateralNeeded = _halfAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _halfAmount + troveManager.get_upfront_fee(_halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

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
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E8"); // 0.1%

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
        assertEq(borrowToken.balanceOf(address(lender)), _amount - _halfAmount, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E24");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E25");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E26");

        // Open a trove for 2nd borrower
        uint256 _secondTroveId = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded * 2, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        _trove = troveManager.troves(_secondTroveId);
        assertEq(_trove.debt, _expectedDebt, "E27");
        assertEq(_trove.collateral, _collateralNeeded * 2, "E28");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E29");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E31");
        assertEq(_trove.owner, anotherUserBorrower, "E32");
        assertEq(_trove.pending_owner, address(0), "E33");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E34");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO * 2, 1e15, "E35"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E36");
        assertEq(sortedTroves.size(), 2, "E37");
        assertEq(sortedTroves.first(), _troveId, "E38");
        assertEq(sortedTroves.last(), _secondTroveId, "E39");
        assertTrue(sortedTroves.contains(_secondTroveId), "E40");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 3, "E41");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E42");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E43");
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E44");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E45");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E46");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * 2, "E46");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 3, "E48");
        assertEq(troveManager.zombie_trove_id(), 0, "E49");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E50");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E51");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E52");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E53");

        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_expectedDebt * 1e18 / priceOracle.price());
        uint256 _secondBorrowAmount = _halfAmount * 101 / 100; // borrow a bit more to wipe out the first borrower
        uint256 _secondExpectedDebt = _secondBorrowAmount + troveManager.get_upfront_fee(_secondBorrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        vm.expectRevert("!route");
        vm.prank(anotherUserBorrower);
        troveManager.borrow(
            _secondTroveId,
            _secondBorrowAmount, // borrow a bit more to wipe out the first borrower
            type(uint256).max, // max_upfront_fee
            2, // route_index
            0 // min_debt_out
        );

        // Add new exchange route
        vm.prank(deployer);
        exchangeHandler.add_route(address(exchangeRoute));

        // Finally borrow more from the trove
        vm.prank(anotherUserBorrower);
        troveManager.borrow(
            _secondTroveId,
            _secondBorrowAmount, // borrow a bit more to wipe out the first borrower
            type(uint256).max, // max_upfront_fee
            2, // route_index
            0 // min_debt_out
        );

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_secondTroveId);
        assertEq(_trove.debt, _expectedDebt + _secondExpectedDebt, "E54");
        assertEq(_trove.collateral, _collateralNeeded * 2, "E55");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E56");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E57");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E58");
        assertEq(_trove.owner, anotherUserBorrower, "E59");
        assertEq(_trove.pending_owner, address(0), "E60");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E61");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 8e15, "E62"); // 0.8%. Slightly worse CR due to increased second borrow amount

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E63");
        assertEq(sortedTroves.size(), 1, "E64");
        assertEq(sortedTroves.first(), _secondTroveId, "E65");
        assertEq(sortedTroves.last(), _secondTroveId, "E66");
        assertTrue(sortedTroves.contains(_secondTroveId), "E67");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption + _collateralNeeded * 2, "E68");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E69");
        assertEq(collateralToken.balanceOf(address(anotherUserBorrower)), 0, "E70");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E71");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E72");
        assertApproxEqRel(borrowToken.balanceOf(anotherUserBorrower), _amount, 25e15, "E73"); // 2.5%. Pays slippage due to the redemption

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E74");
        assertEq(
            troveManager.total_weighted_debt(),
            _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE,
            "E75"
        );
        assertEq(troveManager.collateral_balance(), _expectedCollateralAfterRedemption + _collateralNeeded * 2, "E76");
        assertEq(troveManager.zombie_trove_id(), 0, "E77");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E78");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E79");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E80");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E81");
    }

    function test_borrowFromActiveTrove_zeroDebt(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow 0 debt
        vm.prank(userBorrower);
        vm.expectRevert("!debt_amount");
        troveManager.borrow(
            _troveId,
            0, // debt_amount
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_borrowFromActiveTrove_notOwner(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow from trove as not owner
        vm.prank(anotherUserBorrower);
        vm.expectRevert("!owner");
        troveManager.borrow(
            _troveId,
            _amount,
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_borrowFromActiveTrove_notActiveTrove(
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

        // Try to borrow from a non-active trove
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.borrow(
            _troveId,
            _amount,
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_borrowFromActiveTrove_upfrontFeeTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow with upfront fee too high
        vm.prank(userBorrower);
        vm.expectRevert("!max_upfront_fee");
        troveManager.borrow(
            _troveId,
            _amount,
            0, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_borrowFromActiveTrove_belowMCR(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate the maximum amount that can be borrowed while staying above MCR
        uint256 _maxBorrowable = (_collateralNeeded * priceOracle.price()) / troveManager.MINIMUM_COLLATERAL_RATIO();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow more than is allowed while staying above MCR
        vm.prank(userBorrower);
        vm.expectRevert("!MINIMUM_COLLATERAL_RATIO");
        troveManager.borrow(
            _troveId,
            _maxBorrowable,
            type(uint256).max, // max_upfront_fee
            0, // route_index
            0 // min_debt_out
        );
    }

    function test_borrowFromActiveTrove_notEnoughDebtOut(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow with max debt out
        vm.prank(userBorrower);
        vm.expectRevert("shrekt");
        troveManager.borrow(
            _troveId,
            1, // debt_amount
            type(uint256).max, // max_upfront_fee
            0, // min_debt_out
            type(uint256).max // min_debt_out
        );
    }

    // 1. lend
    // 2. 1st borrower borrows all available liquidity
    // 3. 2nd borrower opens trove with enough collateral
    // 4. 2nd borrower borrows using dutch route, redeems 1st borrower
    function test_borrowFromActiveTrove_usingDutchRoute(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 10, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // First borrower borrows all available liquidity
        uint256 _troveIdVictim = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Accept ownership of dutch route
        vm.prank(management);
        dutchExchangeRoute.accept_ownership();

        // Second borrower opens trove with double collateral (to have room to borrow more)
        uint256 _secondCollateralNeeded = _collateralNeeded * 2;
        uint256 _secondInitialBorrow = troveManager.MIN_DEBT();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondInitialBorrow, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate how much second borrower can borrow to redeem victim completely
        uint256 _borrowAmount = _expectedDebt;
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_expectedDebt * 1e18 / priceOracle.price());

        // Cache userBorrower balance before borrow
        uint256 _userBorrowerBalanceBefore = borrowToken.balanceOf(userBorrower);

        // Borrow using dutch route (route_index=1)
        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _borrowAmount,
            type(uint256).max, // max_upfront_fee
            1, // route_index (dutch route)
            0 // min_debt_out (non-atomic, so 0 is expected)
        );

        // userBorrower should NOT have received borrow tokens yet (dutch auction is non-atomic)
        assertEq(borrowToken.balanceOf(userBorrower), _userBorrowerBalanceBefore, "E1");

        // Check an auction was created
        address _auction = dutchExchangeRoute.auctions(0);
        assertTrue(_auction != address(0), "E2");

        // Auction should be active
        assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E3");

        // Check collateral is in auction
        uint256 _auctionAvailable = IAuction(_auction).available(address(collateralToken));
        assertGt(_auctionAvailable, 0, "E4");

        // Check starting price is set correctly (with 15% buffer)
        uint256 _expectedStartingPrice =
            _auctionAvailable * priceOracle.price() / 1e18 * dutchExchangeRoute.STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18;
        assertEq(IAuction(_auction).startingPrice(), _expectedStartingPrice, "E5");

        // Check minimum price is set correctly (with -5% buffer)
        uint256 _expectedMinimumPrice = priceOracle.price() * dutchExchangeRoute.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18;
        assertEq(IAuction(_auction).minimumPrice(), _expectedMinimumPrice, "E6");

        // Check trove info of victim (should be zombie)
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdVictim);
        assertEq(_trove.debt, 0, "E7");
        assertApproxEqAbs(_trove.collateral, _expectedCollateralAfterRedemption, 1, "E8");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E9");

        // Check trove info of userBorrower (should be active with increased debt)
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.owner, userBorrower, "E10");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E11");

        // Take the auction
        uint256 _amountNeeded = IAuction(_auction).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction, _amountNeeded);
        IAuction(_auction).take(address(collateralToken));
        vm.stopPrank();

        // Auction should be empty now
        assertEq(IAuction(_auction).available(address(collateralToken)), 0, "E12");
        assertFalse(IAuction(_auction).isActive(address(collateralToken)), "E13");

        // userBorrower should have received the borrow tokens (receiver is msg.sender in trove_manager)
        assertEq(borrowToken.balanceOf(userBorrower), _userBorrowerBalanceBefore + _amountNeeded, "E14");

        // Check exchange handler is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E15");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E16");

        // Check dutch route is empty
        assertEq(borrowToken.balanceOf(address(dutchExchangeRoute)), 0, "E17");
        assertEq(collateralToken.balanceOf(address(dutchExchangeRoute)), 0, "E18");

        // Check sorted troves - only userBorrower's trove should be in list
        assertEq(sortedTroves.size(), 1, "E19");
        assertTrue(sortedTroves.contains(_troveId), "E20");
        assertFalse(sortedTroves.contains(_troveIdVictim), "E21");
    }

    // Test that dutch route creates multiple auctions when borrower redeems multiple times concurrently
    function test_borrowFromActiveTrove_usingDutchRoute_multipleAuctions(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 10, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // First borrower (victim) borrows all available liquidity
        uint256 _troveIdVictim = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Accept ownership of dutch route
        vm.prank(management);
        dutchExchangeRoute.accept_ownership();

        // Second borrower opens trove with lots of collateral (to borrow multiple times)
        uint256 _secondCollateralNeeded = _collateralNeeded * 4;
        uint256 _secondInitialBorrow = troveManager.MIN_DEBT();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondInitialBorrow, DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache userBorrower balance before dutch route borrow
        uint256 _userBorrowerBalanceBefore = borrowToken.balanceOf(userBorrower);

        // First borrow - redeems victim completely
        uint256 _firstBorrowAmount = _expectedDebt;

        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _firstBorrowAmount,
            type(uint256).max, // max_upfront_fee
            1, // route_index (dutch route)
            0 // min_debt_out
        );

        // First auction should be created
        address _auction0 = dutchExchangeRoute.auctions(0);
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E1");

        // Victim should be zombie now
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdVictim);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E2");

        // Calculate userBorrower's debt after first borrow
        uint256 _userBorrowerDebtAfterFirst = troveManager.troves(_troveId).debt;

        // Second borrow while first auction is active - redeems userBorrower's own debt (creates second auction)
        uint256 _secondBorrowAmount = _userBorrowerDebtAfterFirst;

        // Create third borrower to do the second redemption
        address _thirdBorrower = address(999);
        uint256 _thirdCollateralNeeded = _secondBorrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price() * 2;
        uint256 _thirdTroveId = mintAndOpenTrove(_thirdBorrower, _thirdCollateralNeeded, troveManager.MIN_DEBT(), DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache thirdBorrower balance before dutch route borrow
        uint256 _thirdBorrowerBalanceBefore = borrowToken.balanceOf(_thirdBorrower);

        vm.prank(_thirdBorrower);
        troveManager.borrow(
            _thirdTroveId,
            _secondBorrowAmount,
            type(uint256).max, // max_upfront_fee
            1, // route_index (dutch route)
            0 // min_debt_out
        );

        // Second auction should be created (different from first) since first is still active
        address _auction1 = dutchExchangeRoute.auctions(1);
        assertTrue(IAuction(_auction1).isActive(address(collateralToken)), "E3");
        assertNotEq(_auction0, _auction1, "E4");

        // Both borrowers should not have received additional tokens yet (dutch is non-atomic)
        assertEq(borrowToken.balanceOf(userBorrower), _userBorrowerBalanceBefore, "E5");
        assertEq(borrowToken.balanceOf(_thirdBorrower), _thirdBorrowerBalanceBefore, "E6");

        // Take both auctions
        uint256 _amountNeeded0 = IAuction(_auction0).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded0);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded0);
        IAuction(_auction0).take(address(collateralToken));
        vm.stopPrank();

        uint256 _amountNeeded1 = IAuction(_auction1).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded1);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction1, _amountNeeded1);
        IAuction(_auction1).take(address(collateralToken));
        vm.stopPrank();

        // Now borrowers should have received their tokens from the auctions
        assertEq(borrowToken.balanceOf(userBorrower), _userBorrowerBalanceBefore + _amountNeeded0, "E7");
        assertEq(borrowToken.balanceOf(_thirdBorrower), _thirdBorrowerBalanceBefore + _amountNeeded1, "E8");

        // Both auctions should be empty
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E9");
        assertFalse(IAuction(_auction1).isActive(address(collateralToken)), "E10");

        // Check exchange handler is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E11");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E12");

        // Check dutch route is empty
        assertEq(borrowToken.balanceOf(address(dutchExchangeRoute)), 0, "E13");
        assertEq(collateralToken.balanceOf(address(dutchExchangeRoute)), 0, "E14");

        // Third borrower's trove should be active
        _trove = troveManager.troves(_thirdTroveId);
        assertEq(_trove.owner, _thirdBorrower, "E15");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E16");

        // userBorrower's trove should be zombie (redeemed by thirdBorrower)
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.owner, userBorrower, "E17");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E18");
    }

}
