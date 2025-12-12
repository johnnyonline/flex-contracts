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
        uint256 _collateralNeeded =
            (_totalBorrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

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
        assertApproxEqRel(
            (_trove.collateral * priceOracle.price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO * 2,
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
        assertEq(borrowToken.balanceOf(address(lender)), _lendAmount - _borrowAmount, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

        // Finally borrow more from the trove
        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _borrowAmount,
            type(uint256).max // max_upfront_fee
        );

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt * 2, "E25");
        assertEq(_trove.collateral, _collateralNeeded, "E26");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E27");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E28");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E29");
        assertEq(_trove.owner, userBorrower, "E30");
        assertEq(_trove.pending_owner, address(0), "E31");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E32");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E33"
        ); // 0.1%

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
        assertEq(borrowToken.balanceOf(userBorrower), _totalBorrowAmount, "E44");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E45");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E46");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E47");
        assertEq(troveManager.zombie_trove_id(), 0, "E48");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E49");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E50");
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
            ((_borrowAmount + troveManager.MIN_DEBT()) * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

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
        assertGt(
            (_trove.collateral * priceOracle.price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            "E8"
        );

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

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

        // Calculate expected debt after second borrow
        uint256 _secondExpectedDebt = _expectedDebt + _borrowAmount + troveManager.get_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally borrow more from the trove
        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _borrowAmount,
            type(uint256).max // max_upfront_fee
        );

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E25");
        assertEq(_trove.collateral, _collateralNeeded, "E26");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E27");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E28");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E29");
        assertEq(_trove.owner, userBorrower, "E30");
        assertEq(_trove.pending_owner, address(0), "E31");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E32");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E33"
        ); // 0.1%

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
        assertEq(borrowToken.balanceOf(userBorrower), _lendAmount, "E44");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E45");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E46");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E47");
        assertEq(troveManager.zombie_trove_id(), 0, "E48");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E49");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E50");
    }

    // 1. lend
    // 2. 1st borrow opens trove with half available liquidity
    // 3. 2nd borrow the other half of available liquidity
    // 4. 2nd borrower borrows again from trove and redeems the 1st borrower completely
    function test_borrowFromActiveTrove_redeemAnotherBorrower(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 2, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Cut in half so we can borrow twice
        uint256 _halfAmount = _amount / 2;

        // Calculate how much collateral is needed for the half borrow amount
        uint256 _collateralNeeded =
            (_halfAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

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
        assertApproxEqRel(
            (_trove.collateral * priceOracle.price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
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
        assertEq(borrowToken.balanceOf(address(lender)), _amount - _halfAmount, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

        // Open a trove for 2nd borrower
        uint256 _secondTroveId = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded * 2, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        _trove = troveManager.troves(_secondTroveId);
        assertEq(_trove.debt, _expectedDebt, "E25");
        assertEq(_trove.collateral, _collateralNeeded * 2, "E26");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E27");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E28");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E29");
        assertEq(_trove.owner, anotherUserBorrower, "E30");
        assertEq(_trove.pending_owner, address(0), "E31");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E32");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO * 2,
            1e15,
            "E33"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E34");
        assertEq(sortedTroves.size(), 2, "E35");
        assertEq(sortedTroves.first(), _troveId, "E36");
        assertEq(sortedTroves.last(), _secondTroveId, "E37");
        assertTrue(sortedTroves.contains(_secondTroveId), "E38");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 3, "E39");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E40");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E41");
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E42");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E43");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E44");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * 2, "E45");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 3, "E46");
        assertEq(troveManager.zombie_trove_id(), 0, "E47");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E48");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E49");

        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_expectedDebt * ORACLE_PRICE_SCALE / priceOracle.price());
        uint256 _secondBorrowAmount = _halfAmount * 101 / 100; // borrow a bit more to wipe out the first borrower
        uint256 _secondExpectedDebt = _secondBorrowAmount + troveManager.get_upfront_fee(_secondBorrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally borrow more from the trove
        vm.prank(anotherUserBorrower);
        troveManager.borrow(
            _secondTroveId,
            _secondBorrowAmount, // borrow a bit more to wipe out the first borrower
            type(uint256).max // max_upfront_fee
        );

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Check an auction was created
        address _auction = dutchDesk.auctions(0);
        assertTrue(_auction != address(0), "E50");

        // Auction should be active
        assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E51");

        // Check collateral is in auction
        uint256 _auctionAvailable = IAuction(_auction).available(address(collateralToken));
        assertGt(_auctionAvailable, 0, "E52");

        // Check starting price is set correctly (with buffer)
        assertEq(
            IAuction(_auction).startingPrice(),
            _auctionAvailable * priceOracle.price(false) / WAD * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION,
            "E53"
        );

        // Check minimum price is set correctly (with buffer)
        assertEq(IAuction(_auction).minimumPrice(), priceOracle.price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD, "E54");

        // Take the auction
        takeAuction(_auction);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_secondTroveId);
        assertEq(_trove.debt, _expectedDebt + _secondExpectedDebt, "E55");
        assertEq(_trove.collateral, _collateralNeeded * 2, "E56");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E57");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E58");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E59");
        assertEq(_trove.owner, anotherUserBorrower, "E60");
        assertEq(_trove.pending_owner, address(0), "E61");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E62");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            8e15,
            "E63"
        ); // 0.8%. Slightly worse CR due to increased second borrow amount

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E64");
        assertEq(sortedTroves.size(), 1, "E65");
        assertEq(sortedTroves.first(), _secondTroveId, "E66");
        assertEq(sortedTroves.last(), _secondTroveId, "E67");
        assertTrue(sortedTroves.contains(_secondTroveId), "E68");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption + _collateralNeeded * 2, "E69");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E70");
        assertEq(collateralToken.balanceOf(address(anotherUserBorrower)), 0, "E71");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E72");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E73");
        assertApproxEqRel(borrowToken.balanceOf(anotherUserBorrower), _amount, 25e15, "E74"); // 2.5%. Pays slippage due to the redemption

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E75");
        assertEq(
            troveManager.total_weighted_debt(),
            _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE,
            "E76"
        );
        assertEq(troveManager.collateral_balance(), _expectedCollateralAfterRedemption + _collateralNeeded * 2, "E77");
        assertEq(troveManager.zombie_trove_id(), 0, "E78");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E79");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E80");
    }

    function test_borrowFromActiveTrove_zeroDebt(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow 0 debt
        vm.prank(userBorrower);
        vm.expectRevert("!debt_amount");
        troveManager.borrow(
            _troveId,
            0, // debt_amount
            type(uint256).max // max_upfront_fee
        );
    }

    function test_borrowFromActiveTrove_notOwner(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow from trove as not owner
        vm.prank(anotherUserBorrower);
        vm.expectRevert("!owner");
        troveManager.borrow(
            _troveId,
            _amount,
            type(uint256).max // max_upfront_fee
        );
    }

    function test_borrowFromActiveTrove_notActiveTrove(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Pull enough liquidity to make trove a zombie trove (but above 0 debt)
        uint256 _amountToPull = _amount - 100 * BORROW_TOKEN_PRECISION;

        // Pull liquidity from lender to make trove a zombie trove (but above 0 debt)
        vm.prank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);

        // Make sure trove is a zombie trove
        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.zombie), "E0");

        // Try to borrow from a non-active trove
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.borrow(
            _troveId,
            _amount,
            type(uint256).max // max_upfront_fee
        );
    }

    function test_borrowFromActiveTrove_upfrontFeeTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow with upfront fee too high
        vm.prank(userBorrower);
        vm.expectRevert("!max_upfront_fee");
        troveManager.borrow(
            _troveId,
            _amount,
            0 // max_upfront_fee
        );
    }

    function test_borrowFromActiveTrove_belowMCR(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

        // Calculate the maximum amount that can be borrowed while staying above MCR
        uint256 _maxBorrowable = (_collateralNeeded * priceOracle.price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / troveManager.MINIMUM_COLLATERAL_RATIO();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow more than is allowed while staying above MCR
        vm.prank(userBorrower);
        vm.expectRevert("!MINIMUM_COLLATERAL_RATIO");
        troveManager.borrow(
            _troveId,
            _maxBorrowable,
            type(uint256).max // max_upfront_fee
        );
    }

    // Test that multiple auctions are created when borrowers redeem concurrently
    function test_borrowFromActiveTrove_multipleAuctions(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 10, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // First borrower (victim) borrows all available liquidity
        uint256 _troveIdVictim = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Second borrower opens trove with lots of collateral (to borrow multiple times)
        uint256 _secondCollateralNeeded = _collateralNeeded * 4;
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, troveManager.MIN_DEBT(), DEFAULT_ANNUAL_INTEREST_RATE);

        // First borrow - redeems victim completely
        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _expectedDebt,
            type(uint256).max // max_upfront_fee
        );

        // First auction should be created
        address _auction0 = dutchDesk.auctions(0);
        assertTrue(_auction0 != address(0), "E1");
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E2");

        // Victim should be zombie now
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdVictim);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E3");

        // Calculate userBorrower's debt after first borrow
        uint256 _userBorrowerDebtAfterFirst = troveManager.troves(_troveId).debt;

        // Create third borrower to do the second redemption
        address _thirdBorrower = address(999);
        uint256 _thirdCollateralNeeded = (_userBorrowerDebtAfterFirst * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price() * 2;
        uint256 _thirdTroveId = mintAndOpenTrove(_thirdBorrower, _thirdCollateralNeeded, troveManager.MIN_DEBT(), DEFAULT_ANNUAL_INTEREST_RATE);

        // Third borrower borrows while first auction is active - redeems userBorrower (creates second auction)
        vm.prank(_thirdBorrower);
        troveManager.borrow(
            _thirdTroveId,
            _userBorrowerDebtAfterFirst,
            type(uint256).max // max_upfront_fee
        );

        // Second auction should be created (different from first) since first is still active
        address _auction1 = dutchDesk.auctions(1);
        assertTrue(_auction1 != address(0), "E4");
        assertTrue(IAuction(_auction1).isActive(address(collateralToken)), "E5");
        assertNotEq(_auction0, _auction1, "E6");

        // Take both auctions
        takeAuction(_auction0);
        takeAuction(_auction1);

        // Both auctions should be empty
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E7");
        assertFalse(IAuction(_auction1).isActive(address(collateralToken)), "E8");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E9");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E10");

        // Third borrower's trove should be active
        _trove = troveManager.troves(_thirdTroveId);
        assertEq(_trove.owner, _thirdBorrower, "E11");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E12");

        // userBorrower's trove should be zombie (redeemed by thirdBorrower)
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.owner, userBorrower, "E13");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E14");
    }

}
