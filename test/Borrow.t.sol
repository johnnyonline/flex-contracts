// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceOracleNotScaled} from "./interfaces/IPriceOracleNotScaled.sol";
import {IPriceOracleScaled} from "./interfaces/IPriceOracleScaled.sol";

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
        _lendAmount = bound(_lendAmount, troveManager.min_debt() * 2, maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, troveManager.min_debt() * 2, _lendAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Cut in half so we can borrow twice
        _borrowAmount = _borrowAmount / 2;

        // Total amount we'll be borrowing
        uint256 _totalBorrowAmount = _borrowAmount * 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_totalBorrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
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
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
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
        _lendAmount = bound(_lendAmount, troveManager.min_debt(), maxFuzzAmount);
        _borrowAmount = bound(_borrowAmount, _lendAmount, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _lendAmount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = ((_borrowAmount + troveManager.min_debt()) * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION)
            * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = troveManager.min_debt() + troveManager.get_upfront_fee(troveManager.min_debt(), DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, troveManager.min_debt(), DEFAULT_ANNUAL_INTEREST_RATE);

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
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
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
        assertEq(borrowToken.balanceOf(address(lender)), _lendAmount - troveManager.min_debt(), "E17");
        assertEq(borrowToken.balanceOf(userBorrower), troveManager.min_debt(), "E18");

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
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
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
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
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
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Cut in half so we can borrow twice
        uint256 _halfAmount = _amount / 2;

        // Calculate how much collateral is needed for the half borrow amount
        uint256 _collateralNeeded =
            (_halfAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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

        // Higher rate for 2nd borrower so he can't redeem the first
        uint256 _higherRate = DEFAULT_ANNUAL_INTEREST_RATE * 2;
        uint256 _secondExpectedDebt = _halfAmount + troveManager.get_upfront_fee(_halfAmount, _higherRate);

        // Open a trove for 2nd borrower
        uint256 _secondTroveId = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded * 2, _halfAmount, _higherRate);

        // Check trove info
        _trove = troveManager.troves(_secondTroveId);
        assertEq(_trove.debt, _secondExpectedDebt, "E25");
        assertEq(_trove.collateral, _collateralNeeded * 2, "E26");
        assertEq(_trove.annual_interest_rate, _higherRate, "E27");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E28");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E29");
        assertEq(_trove.owner, anotherUserBorrower, "E30");
        assertEq(_trove.pending_owner, address(0), "E31");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E32");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO * 2,
            1e15,
            "E33"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E34");
        assertEq(sortedTroves.size(), 2, "E35");
        assertEq(sortedTroves.first(), _secondTroveId, "E36");
        assertEq(sortedTroves.last(), _troveId, "E37");
        assertTrue(sortedTroves.contains(_secondTroveId), "E38");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 3, "E39");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E40");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E41");
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E42");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E43");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt + _secondExpectedDebt, "E44");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE + _secondExpectedDebt * _higherRate, "E45");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 3, "E46");
        assertEq(troveManager.zombie_trove_id(), 0, "E47");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E48");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E49");

        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_expectedDebt * ORACLE_PRICE_SCALE / priceOracle.get_price());
        uint256 _secondBorrowAmount = _halfAmount * 101 / 100; // borrow a bit more to wipe out the first borrower
        uint256 _secondExpectedDebt2 = _secondBorrowAmount + troveManager.get_upfront_fee(_secondBorrowAmount, _higherRate);

        // Finally borrow more from the trove
        vm.prank(anotherUserBorrower);
        troveManager.borrow(
            _secondTroveId,
            _secondBorrowAmount, // borrow a bit more to wipe out the first borrower
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Check an auction was created (nonce incremented)
        assertEq(dutchDesk.nonce(), 1, "E50");

        // Auction should be active
        assertTrue(auction.is_active(0), "E51");

        // Check collateral is in auction
        uint256 _auctionAvailable = auction.get_available_amount(0);
        assertGt(_auctionAvailable, 0, "E52");

        // Check starting price is set correctly (with buffer)
        assertApproxEqAbs(
            auction.starting_price(0),
            _auctionAvailable * priceOracle.get_price(false) / WAD * dutchDesk.starting_price_buffer_percentage() / COLLATERAL_TOKEN_PRECISION,
            3,
            "E53"
        );

        // Check minimum price is set correctly (with buffer)
        assertEq(auction.minimum_price(0), priceOracle.get_price(false) * dutchDesk.minimum_price_buffer_percentage() / WAD, "E54");

        // Take the auction
        takeAuction(0);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_secondTroveId);
        assertEq(_trove.debt, _secondExpectedDebt + _secondExpectedDebt2, "E55");
        assertEq(_trove.collateral, _collateralNeeded * 2, "E56");
        assertEq(_trove.annual_interest_rate, _higherRate, "E57");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E58");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E59");
        assertEq(_trove.owner, anotherUserBorrower, "E60");
        assertEq(_trove.pending_owner, address(0), "E61");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E62");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
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
        assertEq(troveManager.total_debt(), _secondExpectedDebt + _secondExpectedDebt2, "E75");
        assertEq(troveManager.total_weighted_debt(), (_secondExpectedDebt + _secondExpectedDebt2) * _higherRate, "E76");
        assertEq(troveManager.collateral_balance(), _expectedCollateralAfterRedemption + _collateralNeeded * 2, "E77");
        assertEq(troveManager.zombie_trove_id(), 0, "E78");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E79");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E80");
    }

    function test_borrowFromActiveTrove_zeroDebt(
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

        // Try to borrow 0 debt
        vm.prank(userBorrower);
        vm.expectRevert("!debt_amount");
        troveManager.borrow(
            _troveId,
            0, // debt_amount
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );
    }

    function test_borrowFromActiveTrove_notOwner(
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

        // Try to borrow from trove as not owner
        vm.prank(anotherUserBorrower);
        vm.expectRevert("!owner");
        troveManager.borrow(
            _troveId,
            _amount,
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );
    }

    function test_borrowFromActiveTrove_notActiveTrove(
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

        // Try to borrow from a non-active trove
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.borrow(
            _troveId,
            _amount,
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );
    }

    function test_borrowFromActiveTrove_upfrontFeeTooHigh(
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

        // Try to borrow with upfront fee too high
        vm.prank(userBorrower);
        vm.expectRevert("!max_upfront_fee");
        troveManager.borrow(
            _troveId,
            _amount,
            0, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );
    }

    function test_borrowFromActiveTrove_belowMCR(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Calculate the maximum amount that can be borrowed while staying above MCR
        uint256 _maxBorrowable =
            (_collateralNeeded * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / troveManager.minimum_collateral_ratio();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to borrow more than is allowed while staying above MCR
        vm.prank(userBorrower);
        vm.expectRevert("!minimum_collateral_ratio");
        troveManager.borrow(
            _troveId,
            _maxBorrowable,
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );
    }

    // Test that multiple auctions are created when borrowers redeem concurrently
    function test_borrowFromActiveTrove_multipleAuctions(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 10, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // First borrower (victim) borrows all available liquidity
        uint256 _troveIdVictim = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Second borrower opens trove - redeems victim partially (creates auction 0)
        uint256 _secondCollateralNeeded = _collateralNeeded * 4;
        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, troveManager.min_debt(), DEFAULT_ANNUAL_INTEREST_RATE * 2);

        // First auction created from opening trove
        assertEq(dutchDesk.nonce(), 1, "E1");
        assertTrue(auction.is_active(0), "E2");

        // Take auction immediately to avoid time skip issues
        takeAuction(0);
        assertFalse(auction.is_active(0), "E3");

        // Second borrower borrows more - redeems victim again (creates auction 1)
        vm.prank(userBorrower);
        troveManager.borrow(_troveId, _expectedDebt, type(uint256).max, 0, 0);

        // Second auction created
        assertEq(dutchDesk.nonce(), 2, "E4");
        assertTrue(auction.is_active(1), "E5");

        // Victim should be zombie now
        assertEq(uint256(troveManager.troves(_troveIdVictim).status), uint256(ITroveManager.Status.zombie), "E6");

        // Take auction immediately
        takeAuction(1);
        assertFalse(auction.is_active(1), "E7");

        // Third borrower opens trove - redeems userBorrower partially (creates auction 2)
        address _thirdBorrower = address(999);
        uint256 _thirdCollateralNeeded = (troveManager.troves(_troveId).debt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION)
            * ORACLE_PRICE_SCALE / priceOracle.get_price() * 2;
        uint256 _thirdTroveId = mintAndOpenTrove(_thirdBorrower, _thirdCollateralNeeded, troveManager.min_debt(), DEFAULT_ANNUAL_INTEREST_RATE * 3);

        // Third auction created
        assertEq(dutchDesk.nonce(), 3, "E8");
        assertTrue(auction.is_active(2), "E9");

        // Take auction immediately
        takeAuction(2);
        assertFalse(auction.is_active(2), "E10");

        // Third borrower borrows - redeems userBorrower again (creates auction 3)
        vm.startPrank(_thirdBorrower);
        troveManager.borrow(_thirdTroveId, troveManager.troves(_troveId).debt, type(uint256).max, 0, 0);
        vm.stopPrank();

        // Fourth auction created
        assertEq(dutchDesk.nonce(), 4, "E11");
        assertTrue(auction.is_active(3), "E12");

        // Take last auction
        takeAuction(3);
        assertFalse(auction.is_active(3), "E13");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E14");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E15");

        // Third borrower's trove should be active
        assertEq(troveManager.troves(_thirdTroveId).owner, _thirdBorrower, "E16");
        assertEq(uint256(troveManager.troves(_thirdTroveId).status), uint256(ITroveManager.Status.active), "E17");

        // userBorrower's trove should be zombie (redeemed by thirdBorrower)
        assertEq(troveManager.troves(_troveId).owner, userBorrower, "E18");
        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.zombie), "E19");
    }

    // 1. lend
    // 2. 1st borrower opens trove at high rate
    // 3. 2nd borrower opens trove at low rate (takes remaining liquidity)
    // 4. 2nd borrower tries to borrow more -> can't redeem higher rate borrower, gets nothing
    function test_borrowFromActiveTrove_cannotRedeemHigherRateBorrower(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _halfAmount = _amount / 2;

        // 1st borrower opens a trove at a higher rate (takes half liquidity)
        uint256 _higherRate = DEFAULT_ANNUAL_INTEREST_RATE * 2;
        mintAndOpenTrove(anotherUserBorrower, _collateralNeeded / 2, _halfAmount, _higherRate);

        // 2nd borrower opens a trove at lower rate (takes remaining liquidity, with extra collateral for later borrow)
        uint256 _lowerRate = DEFAULT_ANNUAL_INTEREST_RATE;
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded * 2, _halfAmount, _lowerRate);

        // Make sure there's no liquidity left in the lender
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E0");

        uint256 _balanceBefore = borrowToken.balanceOf(userBorrower);

        // 2nd borrower tries to borrow more - can't redeem the higher rate borrower
        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _halfAmount, // try to borrow more
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );

        // 2nd borrower should have received nothing additional (no liquidity, can't redeem)
        assertApproxEqAbs(borrowToken.balanceOf(userBorrower), _balanceBefore, 1, "E1");

        // Both troves should still be active
        assertEq(sortedTroves.size(), 2, "E2");
    }

    // 1. lend
    // 2. 1st borrower opens trove at low rate
    // 3. 2nd borrower opens trove at high rate (takes remaining liquidity)
    // 4. 2nd borrower borrows more -> can redeem the lower rate borrower
    function test_borrowFromActiveTrove_canRedeemLowerRateBorrower(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _halfAmount = _amount / 2;

        // 1st borrower opens a trove at a lower rate (takes half liquidity)
        uint256 _lowerRate = DEFAULT_ANNUAL_INTEREST_RATE;
        uint256 _troveIdVictim = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded / 2, _halfAmount, _lowerRate);

        // 2nd borrower opens a trove at higher rate (takes remaining liquidity, with extra collateral for later borrow)
        uint256 _higherRate = DEFAULT_ANNUAL_INTEREST_RATE * 2;
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded * 2, _halfAmount, _higherRate);

        // Make sure there's no liquidity left in the lender
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E0");

        // Calculate victim's debt
        uint256 _victimDebt = _halfAmount + troveManager.get_upfront_fee(_halfAmount, _lowerRate);

        // 2nd borrower borrows more - can redeem the lower rate borrower
        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _victimDebt, // borrow enough to fully redeem victim
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );

        // An auction should have been created (redemption occurred)
        assertTrue(auction.is_active(0), "E1");

        // Take the auction
        takeAuction(0);

        // 1st borrower's trove should now be a zombie (fully redeemed)
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdVictim);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E2");
    }

    // Zombie troves can be redeemed by anyone regardless of interest rate (via borrow)
    function test_borrowFromActiveTrove_canRedeemZombieTroveAtAnyRate(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // 1st borrower opens a trove at a high rate (takes all liquidity)
        uint256 _highRate = troveManager.min_annual_interest_rate() * 2;
        uint256 _troveIdVictim = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, _highRate);

        // Make sure there's no liquidity left in the lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        // Make the victim a zombie via Lender withdrawal (Lender can redeem anyone regardless of rate)
        // Pull enough liquidity to make trove a zombie (but above 0 debt)
        uint256 _amountToPull = _amount - 100 * BORROW_TOKEN_PRECISION;

        vm.prank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);

        // Take the auction created by redemption
        takeAuction(0);

        // Victim should now be a zombie with remaining debt
        ITroveManager.Trove memory _trove = troveManager.troves(_troveIdVictim);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E1");
        assertGt(_trove.debt, 0, "E2"); // still has some debt

        // 2nd borrower opens a trove at min rate (much lower than zombie's rate)
        // with extra collateral to borrow more later
        uint256 _minRate = troveManager.min_annual_interest_rate();
        uint256 _initialBorrow = troveManager.min_debt();
        uint256 _secondCollateralNeeded = ((_initialBorrow + _trove.debt * 2) * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION)
            * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId = mintAndOpenTrove(userBorrower, _secondCollateralNeeded, _initialBorrow, _minRate);

        // Now borrow more - should be able to redeem the zombie even with lower rate
        vm.prank(userBorrower);
        troveManager.borrow(
            _troveId,
            _trove.debt, // borrow enough to clear zombie's remaining debt
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );

        // Take the auction (zombie redemption)
        takeAuction(1);

        // Zombie should now have 0 debt (fully redeemed by low-rate borrower)
        _trove = troveManager.troves(_troveIdVictim);
        assertEq(_trove.debt, 0, "E3");
    }

    function test_borrowFromActiveTrove_minDebtOutTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded * 2, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        uint256 _lenderBalance = borrowToken.balanceOf(address(lender));

        vm.prank(userBorrower);
        vm.expectRevert("!min_borrow_out");
        troveManager.borrow(
            _troveId,
            _amount,
            type(uint256).max,
            _lenderBalance + 1, // min_borrow_out higher than available
            0 // min_collateral_out
        );
    }

    function test_borrowFromActiveTrove_minCollateralOutTooHigh(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // 1st borrower takes all liquidity
        mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // 2nd borrower opens trove with extra collateral for later borrow
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded * 2, troveManager.min_debt(), DEFAULT_ANNUAL_INTEREST_RATE * 2);

        // 2nd borrower tries to borrow with min_collateral_out higher than what can be redeemed
        vm.prank(userBorrower);
        vm.expectRevert("!min_collateral_out");
        troveManager.borrow(
            _troveId,
            _amount,
            type(uint256).max,
            0, // min_borrow_out
            type(uint256).max // min_collateral_out higher than what can be redeemed
        );
    }

}
