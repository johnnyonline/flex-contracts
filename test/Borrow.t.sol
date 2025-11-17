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
            1, // route_index
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
            1, // route_index
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

}
