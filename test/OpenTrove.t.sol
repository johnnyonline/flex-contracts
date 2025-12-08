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
        assertEq(borrowToken.balanceOf(address(lender)), _lendAmount - _borrowAmount, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _borrowAmount, "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");
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
        uint256 _expectedDebt = _borrowAmount + troveManager.get_upfront_fee(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);

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
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _availableLiquidity, "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");
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
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_expectedDebt * 1e18 / priceOracle.price());

        // Second amount is slightly more than the first amount, just enough to cover the upfront fee
        uint256 _secondAmount = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondCollateralNeeded = _secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();
        uint256 _secondExpectedDebt = _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Open a trove and redeem from the other borrower
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check an auction was created
        address _auction = dutchDesk.auctions(0);
        assertTrue(_auction != address(0), "E1");

        // Auction should be active
        assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E2");

        // Check collateral is in auction
        uint256 _auctionAvailable = IAuction(_auction).available(address(collateralToken));
        assertGt(_auctionAvailable, 0, "E3");

        // Check starting price is set correctly (with buffer)
        assertEq(
            IAuction(_auction).startingPrice(),
            _auctionAvailable * priceOracle.price() / 1e18 * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18,
            "E4"
        );

        // Check minimum price is set correctly (with buffer)
        assertEq(IAuction(_auction).minimumPrice(), priceOracle.price() * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18, "E5");

        // Take the auction
        takeAuction(_auction);

        // Auction should be empty now
        assertEq(IAuction(_auction).available(address(collateralToken)), 0, "E6");
        assertFalse(IAuction(_auction).isActive(address(collateralToken)), "E7");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, 0, "E8");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E9");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E10");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E11");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E12");
        assertEq(_trove.owner, anotherUserBorrower, "E13");
        assertEq(_trove.pending_owner, address(0), "E14");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E15");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E16");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E17");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E18");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E19");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E20");
        assertEq(_trove.owner, userBorrower, "E21");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E22");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E23"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E24");
        assertEq(sortedTroves.size(), 1, "E25");
        assertEq(sortedTroves.first(), _troveId, "E26");
        assertEq(sortedTroves.last(), _troveId, "E27");
        assertTrue(sortedTroves.contains(_troveId), "E28");
        assertFalse(sortedTroves.contains(_troveIdAnotherBorrower), "E29");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E30");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E31");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E32");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E33");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E34"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount, "E35");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E36");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E37");
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E38");
        assertEq(troveManager.zombie_trove_id(), 0, "E39");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E40");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E41");
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
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure half of the liquidity was taken from the lender
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), _firstAmount, 2, "E0");

        // Second amount is slightly more than the first amount, not too much more though, to leave the first borrower above min debt
        uint256 _secondAmount = _firstAmount * 110 / 100; // 10% more
        _secondAmount += troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondCollateralNeeded = _secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();
        uint256 _secondExpectedDebt = _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Open a trove and redeem from the other borrower
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected debt (borrow amount + upfront fee - redeemed debt)
        uint256 _expectedDebt = _amount - _secondAmount + troveManager.get_upfront_fee(_firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected collateral after redemption (only need to redeem the difference between the two amounts)
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - ((_secondAmount - _firstAmount) * 1e18 / priceOracle.price());

        // Check an auction was created
        assertTrue(dutchDesk.auctions(0) != address(0), "E1");

        // Auction should be active
        assertTrue(IAuction(dutchDesk.auctions(0)).isActive(address(collateralToken)), "E2");

        // Check collateral is in auction
        uint256 _auctionAvailable = IAuction(dutchDesk.auctions(0)).available(address(collateralToken));
        assertGt(_auctionAvailable, 0, "E3");

        // Check starting price is set correctly (with buffer)
        assertEq(
            IAuction(dutchDesk.auctions(0)).startingPrice(),
            _auctionAvailable * priceOracle.price() / 1e18 * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18,
            "E4"
        );

        // Check minimum price is set correctly (with buffer)
        assertEq(IAuction(dutchDesk.auctions(0)).minimumPrice(), priceOracle.price() * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18, "E5");

        // Take the auction
        takeAuction(dutchDesk.auctions(0));

        // Auction should be empty now
        assertEq(IAuction(dutchDesk.auctions(0)).available(address(collateralToken)), 0, "E6");
        assertFalse(IAuction(dutchDesk.auctions(0)).isActive(address(collateralToken)), "E7");

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E8");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E9");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E10");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E11");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E12");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E13");
        assertEq(_trove.owner, anotherUserBorrower, "E14");
        assertEq(_trove.pending_owner, address(0), "E15");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E16");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E17");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E18");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E19");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E20");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E21");
        assertEq(_trove.owner, userBorrower, "E22");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E23");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E24"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E25");
        assertEq(sortedTroves.size(), 2, "E26");
        assertEq(sortedTroves.first(), _troveIdAnotherBorrower, "E27");
        assertEq(sortedTroves.last(), _troveId, "E28");
        assertTrue(sortedTroves.contains(_troveId), "E29");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E30");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E31");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E32");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E33");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E34");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E35"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount / 2, "E36");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E37");
        assertEq(
            troveManager.total_weighted_debt(),
            _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE,
            "E38"
        );
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E39");
        assertEq(troveManager.zombie_trove_id(), 0, "E40");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E41");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E42");
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

        // Calculate target collateral ratio (10% above MCR)
        uint256 _targetCollateralRatio = troveManager.MINIMUM_COLLATERAL_RATIO() * 110 / 100;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * _targetCollateralRatio / priceOracle.price();

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _secondCollateralNeeded = _secondAmount * _targetCollateralRatio / priceOracle.price();

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Open a trove that tries to redeem from the other borrower and revert because it would leave them below min debt (but above 0)
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected debt (borrow amount + upfront fee - redeemed debt)
        uint256 _expectedDebt = _amount - _secondAmount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected collateral after redemption (only need to redeem the difference between the two amounts)
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_secondAmount * 1e18 / priceOracle.price());

        // Check an auction was created
        assertTrue(dutchDesk.auctions(0) != address(0), "E1");

        // Auction should be active
        assertTrue(IAuction(dutchDesk.auctions(0)).isActive(address(collateralToken)), "E2");

        // Check collateral is in auction
        uint256 _auctionAvailable = IAuction(dutchDesk.auctions(0)).available(address(collateralToken));
        assertGt(_auctionAvailable, 0, "E3");

        // Check starting price is set correctly (with buffer)
        assertEq(
            IAuction(dutchDesk.auctions(0)).startingPrice(),
            _auctionAvailable * priceOracle.price() / 1e18 * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18,
            "E4"
        );

        // Check minimum price is set correctly (with buffer)
        assertEq(IAuction(dutchDesk.auctions(0)).minimumPrice(), priceOracle.price() * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18, "E5");

        // Take the auction
        takeAuction(dutchDesk.auctions(0));

        // Auction should be empty now
        assertEq(IAuction(dutchDesk.auctions(0)).available(address(collateralToken)), 0, "E6");
        assertFalse(IAuction(dutchDesk.auctions(0)).isActive(address(collateralToken)), "E7");

        // Calculate expected debt for the second borrower
        uint256 _secondExpectedDebt = _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E8");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E9");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E10");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E11");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E12");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E13");
        assertEq(_trove.owner, anotherUserBorrower, "E14");
        assertEq(_trove.pending_owner, address(0), "E15");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E16");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E17");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E18");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E19");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E20");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E21");
        assertEq(_trove.owner, userBorrower, "E22");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E23");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E24"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E25");
        assertEq(sortedTroves.size(), 1, "E26");
        assertEq(sortedTroves.first(), _troveId, "E27");
        assertEq(sortedTroves.last(), _troveId, "E28");
        assertTrue(sortedTroves.contains(_troveId), "E29");
        assertFalse(sortedTroves.contains(_troveIdAnotherBorrower), "E30");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E31");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E32");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E33");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E34");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E35"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount, "E36");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E37");
        assertEq(
            troveManager.total_weighted_debt(),
            _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE,
            "E38"
        );
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E39");
        assertEq(troveManager.zombie_trove_id(), _troveIdAnotherBorrower, "E40");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E41");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E42");
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
            type(uint256).max // max_upfront_fee
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
            type(uint256).max // max_upfront_fee
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
            type(uint256).max // max_upfront_fee
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
            type(uint256).max // max_upfront_fee
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
            type(uint256).max // max_upfront_fee
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
            _upfrontFee - 1 // max_upfront_fee
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
            type(uint256).max // max_upfront_fee
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
            type(uint256).max // max_upfront_fee
        );
    }

    // Test that multiple auctions are created when multiple borrowers redeem concurrently
    function test_openTrove_multipleAuctions(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 10, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Borrow all available liquidity from first victim
        uint256 _troveIdVictim1 = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate victim's debt
        uint256 _victimDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // First redeemer opens trove - redeems victim completely
        uint256 _firstAmount = _victimDebt;
        uint256 _firstCollateralNeeded = _firstAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        uint256 _troveId1 = mintAndOpenTrove(userBorrower, _firstCollateralNeeded, _firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // First auction should be created
        address _auction0 = dutchDesk.auctions(0);
        assertTrue(_auction0 != address(0), "E1");
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E2");

        // First victim should be zombie now
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdVictim1);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E3");

        // Create a third borrower address (will be second redeemer)
        address _thirdBorrower = address(999);

        // Second redeemer opens trove and redeems first redeemer
        uint256 _firstExpectedDebt = _firstAmount + troveManager.get_upfront_fee(_firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondAmount = _firstExpectedDebt;
        uint256 _secondCollateralNeeded = _secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        uint256 _troveId2 = mintAndOpenTrove(_thirdBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Second auction should be created (different from first) since first is still active
        address _auction1 = dutchDesk.auctions(1);
        assertTrue(_auction1 != address(0), "E4");
        assertTrue(IAuction(_auction1).isActive(address(collateralToken)), "E5");
        assertNotEq(_auction0, _auction1, "E6");

        // Both borrowers should not have received tokens yet (auctions not taken)
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E7");
        assertEq(borrowToken.balanceOf(_thirdBorrower), 0, "E8");

        // Take both auctions
        takeAuction(_auction0);
        takeAuction(_auction1);

        // Both auctions should be empty
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E9");
        assertFalse(IAuction(_auction1).isActive(address(collateralToken)), "E10");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E11");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E12");

        // Check second new trove is active (second redeemer redeemed first redeemer)
        _trove = troveManager.troves(_troveId2);
        assertEq(_trove.owner, _thirdBorrower, "E13");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E14");

        // First redeemer's trove should be zombie (redeemed by second redeemer)
        _trove = troveManager.troves(_troveId1);
        assertEq(_trove.owner, userBorrower, "E15");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E16");
    }

}
