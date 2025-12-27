// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceOracleNotScaled} from "./interfaces/IPriceOracleNotScaled.sol";
import {IPriceOracleScaled} from "./interfaces/IPriceOracleScaled.sol";

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
        uint256 _collateralNeeded =
            (_borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
        uint256 _collateralNeeded =
            (_borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_expectedDebt * ORACLE_PRICE_SCALE / priceOracle.get_price());

        // Second amount is slightly more than the first amount, just enough to cover the upfront fee
        uint256 _secondAmount = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondCollateralNeeded =
            (_secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _secondExpectedDebt = _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Open a trove and redeem from the other borrower
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check an auction was created
        uint256 _auctionId = 0;
        assertTrue(auction.is_active(_auctionId), "E1");

        // Check collateral is in auction
        uint256 _auctionAvailable = auction.get_available_amount(_auctionId);
        assertGt(_auctionAvailable, 0, "E2");

        // Check starting price is set correctly (with buffer)
        assertEq(
            auction.starting_price(_auctionId),
            _auctionAvailable * priceOracle.get_price(false) / WAD * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION,
            "E3"
        );

        // Check minimum price is set correctly (with buffer)
        assertEq(auction.minimum_price(_auctionId), priceOracle.get_price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD, "E4");

        // Take the auction
        takeAuction(_auctionId);

        // Auction should be empty now
        assertEq(auction.get_available_amount(_auctionId), 0, "E5");
        assertFalse(auction.is_active(_auctionId), "E6");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, 0, "E7");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E8");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E9");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E10");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E11");
        assertEq(_trove.owner, anotherUserBorrower, "E12");
        assertEq(_trove.pending_owner, address(0), "E13");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E14");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E15");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E16");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E17");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E18");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E19");
        assertEq(_trove.owner, userBorrower, "E20");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E21");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E22"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E23");
        assertEq(sortedTroves.size(), 1, "E24");
        assertEq(sortedTroves.first(), _troveId, "E25");
        assertEq(sortedTroves.last(), _troveId, "E26");
        assertTrue(sortedTroves.contains(_troveId), "E27");
        assertFalse(sortedTroves.contains(_troveIdAnotherBorrower), "E28");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E29");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E30");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E31");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E32");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E33"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount, "E34");

        // Check global info
        assertEq(troveManager.total_debt(), _secondExpectedDebt, "E35");
        assertEq(troveManager.total_weighted_debt(), _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E36");
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E37");
        assertEq(troveManager.zombie_trove_id(), 0, "E38");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E39");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E40");
    }

    // 1. lend
    // 2. 1st borrower borrows some
    // 3. 2nd borrower borrows rest + some (redeems 1st borrower (but leaves him above min debt) and takes all remaining liquidity)
    function test_openTrove_borrowSomeAvailableLiquidity_andBorrowTheRestAndRedeemSome(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 250 / 100, maxFuzzAmount); // Lend at least 2.5x min debt

        // Zero out last digit to avoid funny precision issues
        _amount = (_amount / 10) * 10;

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // First borrower borrows half the available liquidity
        uint256 _firstAmount = _amount / 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_firstAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure half of the liquidity was taken from the lender
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), _firstAmount, 2, "E0");

        // Second amount is slightly more than the first amount, not too much more though, to leave the first borrower above min debt
        uint256 _secondAmount = _firstAmount * 110 / 100; // 10% more
        _secondAmount += troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondCollateralNeeded =
            (_secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _secondExpectedDebt = _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Open a trove and redeem from the other borrower
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected debt (borrow amount + upfront fee - redeemed debt)
        uint256 _expectedDebt = _amount - _secondAmount + troveManager.get_upfront_fee(_firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected collateral after redemption (only need to redeem the difference between the two amounts)
        uint256 _expectedCollateralAfterRedemption =
            _collateralNeeded - ((_secondAmount - _firstAmount) * ORACLE_PRICE_SCALE / priceOracle.get_price());

        // Check an auction was created
        // uint256 _auctionId = 0;
        assertTrue(auction.is_active(0), "E1");

        // Check collateral is in auction
        uint256 _auctionAvailable = auction.get_available_amount(0);
        assertGt(_auctionAvailable, 0, "E2");

        // Check starting price is set correctly (with buffer)
        assertEq(
            auction.starting_price(0),
            _auctionAvailable * priceOracle.get_price(false) / WAD * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION,
            "E3"
        );

        // Check minimum price is set correctly (with buffer)
        assertEq(auction.minimum_price(0), priceOracle.get_price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD, "E4");

        // Take the auction
        takeAuction(0);

        // Auction should be empty now
        assertEq(auction.get_available_amount(0), 0, "E5");
        assertFalse(auction.is_active(0), "E6");

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E7");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E8");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E9");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E10");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E11");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E12");
        assertEq(_trove.owner, anotherUserBorrower, "E13");
        assertEq(_trove.pending_owner, address(0), "E14");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E15");

        // Check trove info of userBorrower
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E16");
        assertEq(_trove.collateral, _secondCollateralNeeded, "E17");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E18");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E19");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E20");
        assertEq(_trove.owner, userBorrower, "E21");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E22");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E23"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E24");
        assertEq(sortedTroves.size(), 2, "E25");
        assertEq(sortedTroves.first(), _troveIdAnotherBorrower, "E26");
        assertEq(sortedTroves.last(), _troveId, "E27");
        assertTrue(sortedTroves.contains(_troveId), "E28");
        assertTrue(sortedTroves.contains(_troveIdAnotherBorrower), "E29");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E30");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E31");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E32");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E33");
        assertApproxEqRel(borrowToken.balanceOf(userBorrower), _secondAmount, 25e15, "E34"); // 2.5%. Pays slippage due to the redemption
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _amount / 2, "E35");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E36");
        assertEq(
            troveManager.total_weighted_debt(),
            _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE,
            "E37"
        );
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E38");
        assertEq(troveManager.zombie_trove_id(), 0, "E39");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E40");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E41");
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
        uint256 _collateralNeeded = (_amount * _targetCollateralRatio / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Borrow all available liquidity from another borrower
        uint256 _troveIdAnotherBorrower = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _secondCollateralNeeded =
            (_secondAmount * _targetCollateralRatio / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Open a trove that tries to redeem from the other borrower and revert because it would leave them below min debt (but above 0)
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected debt (borrow amount + upfront fee - redeemed debt)
        uint256 _expectedDebt = _amount - _secondAmount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate expected collateral after redemption (only need to redeem the difference between the two amounts)
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_secondAmount * ORACLE_PRICE_SCALE / priceOracle.get_price());

        // Check an auction was created
        // uint256 _auctionId = 0;
        assertTrue(auction.is_active(0), "E1");

        // Check collateral is in auction
        uint256 _auctionAvailable = auction.get_available_amount(0);
        assertGt(_auctionAvailable, 0, "E2");

        // Check starting price is set correctly (with buffer)
        assertEq(
            auction.starting_price(0),
            _auctionAvailable * priceOracle.get_price(false) / WAD * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / WAD / COLLATERAL_TOKEN_PRECISION,
            "E3"
        );

        // Check minimum price is set correctly (with buffer)
        assertEq(auction.minimum_price(0), priceOracle.get_price(false) * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / WAD, "E4");

        // Take the auction
        takeAuction(0);

        // Auction should be empty now
        assertEq(auction.get_available_amount(0), 0, "E5");
        assertFalse(auction.is_active(0), "E6");

        // Calculate expected debt for the second borrower
        uint256 _secondExpectedDebt = _secondAmount + troveManager.get_upfront_fee(_secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E7");

        // Check trove info of anotherUserBorrower
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdAnotherBorrower);
        assertEq(_trove.debt, _expectedDebt, "E8");
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
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E23"
        ); // 0.1%

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
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E36");
        assertEq(
            troveManager.total_weighted_debt(),
            _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * DEFAULT_ANNUAL_INTEREST_RATE,
            "E37"
        );
        assertEq(troveManager.collateral_balance(), _secondCollateralNeeded + _expectedCollateralAfterRedemption, "E38");
        assertEq(troveManager.zombie_trove_id(), _troveIdAnotherBorrower, "E39");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E40");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E41");
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
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
        uint256 _collateralNeeded =
            (_amount * (troveManager.MINIMUM_COLLATERAL_RATIO() - 1) / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Borrow all available liquidity from first victim
        uint256 _troveIdVictim1 = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Calculate victim's debt
        uint256 _victimDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // First redeemer opens trove - redeems victim completely
        uint256 _firstAmount = _victimDebt;
        uint256 _firstCollateralNeeded =
            (_firstAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId1 = mintAndOpenTrove(userBorrower, _firstCollateralNeeded, _firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // First auction should be created
        uint256 _auctionId0 = 0;
        assertTrue(auction.is_active(_auctionId0), "E1");

        // First victim should be zombie now
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdVictim1);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E2");

        // Create a third borrower address (will be second redeemer)
        address _thirdBorrower = address(999);

        // Second redeemer opens trove and redeems first redeemer
        uint256 _firstExpectedDebt = _firstAmount + troveManager.get_upfront_fee(_firstAmount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _secondAmount = _firstExpectedDebt;
        uint256 _secondCollateralNeeded =
            _secondAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId2 = mintAndOpenTrove(_thirdBorrower, _secondCollateralNeeded, _secondAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Second auction should be created (different from first) since first is still active
        uint256 _auctionId1 = 1;
        assertTrue(auction.is_active(_auctionId1), "E3");

        // Both borrowers should not have received tokens yet (auctions not taken)
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E4");
        assertEq(borrowToken.balanceOf(_thirdBorrower), 0, "E5");

        // Take both auctions
        takeAuction(_auctionId0);
        takeAuction(_auctionId1);

        // Both auctions should be empty
        assertFalse(auction.is_active(_auctionId0), "E6");
        assertFalse(auction.is_active(_auctionId1), "E7");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E8");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E9");

        // Check second new trove is active (second redeemer redeemed first redeemer)
        _trove = troveManager.troves(_troveId2);
        assertEq(_trove.owner, _thirdBorrower, "E10");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E11");

        // First redeemer's trove should be zombie (redeemed by second redeemer)
        _trove = troveManager.troves(_troveId1);
        assertEq(_trove.owner, userBorrower, "E12");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E13");
    }

    // 1. lend
    // 2. 1st borrower borrows all liquidity
    // 3. liquidate the 1st borrower (creates liquidation auction)
    // 4. 2nd borrower tries to open trove (needs to redeem) -> reverts with "liquidation"
    function test_openTrove_blockedDuringLiquidation(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a trove (takes all liquidity)
        uint256 _troveId = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Get trove info for price calculation
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);

        // Calculate price drop to put trove below MCR (1% below)
        uint256 _priceDropToBelowMCR;
        if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
            _priceDropToBelowMCR =
                troveManager.MINIMUM_COLLATERAL_RATIO() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
        } else {
            _priceDropToBelowMCR =
                troveManager.MINIMUM_COLLATERAL_RATIO() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
        }
        uint256 _priceDropToBelowMCR18 = _priceDropToBelowMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);

        // Mock the oracle price
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceDropToBelowMCR));
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_priceDropToBelowMCR18));

        // Liquidate the trove
        uint256[MAX_ITERATIONS] memory _troveIdsToLiquidate;
        _troveIdsToLiquidate[0] = _troveId;
        troveManager.liquidate_troves(_troveIdsToLiquidate);

        // Liquidation auction is now ongoing
        assertTrue(auction.is_ongoing_liquidation_auction(), "E1");

        // Calculate collateral needed for new trove (use new price)
        uint256 _newCollateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / _priceDropToBelowMCR;

        // Give userBorrower enough collateral
        deal(address(collateralToken), userBorrower, _newCollateralNeeded);

        // Try to open a new trove - should revert because it needs to redeem and there's an ongoing liquidation
        vm.startPrank(userBorrower);
        collateralToken.approve(address(troveManager), _newCollateralNeeded);
        vm.expectRevert("liquidation");
        troveManager.open_trove(
            block.timestamp, // owner_index
            _newCollateralNeeded, // collateral_amount
            _amount, // debt_amount
            0, // upper_hint
            0, // lower_hint
            DEFAULT_ANNUAL_INTEREST_RATE, // annual_interest_rate
            type(uint256).max // max_upfront_fee
        );
        vm.stopPrank();
    }

}
