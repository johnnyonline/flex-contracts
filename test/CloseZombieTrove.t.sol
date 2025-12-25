// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract CloseZombieTroveTests is Base {

    function setUp() public override {
        Base.setUp();

        // Set `profitMaxUnlockTime` to 0
        vm.prank(management);
        lender.setProfitMaxUnlockTime(0);

        // Set fees to 0
        vm.prank(management);
        lender.setPerformanceFee(0);
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. Pull liquidity to leave borrower with a zombie trove (but above 0 debt)
    // 4. close zombie trove
    function test_closeZombieTrove(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

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
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

        // Pull enough liquidity to make trove a zombie trove (but above 0 debt)
        uint256 _amountToPull = _amount - 100 * BORROW_TOKEN_PRECISION;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_amountToPull * ORACLE_PRICE_SCALE / priceOracle.get_price());

        // Pull liquidity from lender to make trove a zombie trove (but above 0 debt)
        vm.startPrank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);
        vm.stopPrank();

        // Take the auction
        uint256 _timeSkipped = takeAuction(0);

        // Do some intermediate checks on lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E25");
        assertApproxEqRel(borrowToken.balanceOf(address(userLender)), _amountToPull, 3e16, "E26"); // 3% Slippage

        // Do some intermediate checks on borrower
        _trove = troveManager.troves(_troveId);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E27");
        assertEq(_trove.debt, _expectedDebt - _amountToPull, "E28");
        assertEq(troveManager.zombie_trove_id(), _troveId, "E29");

        // Add interest from the time skipped during the auction
        uint256 _newExpectedDebt =
            (_expectedDebt - _amountToPull) + _timeSkipped * _trove.debt * _trove.annual_interest_rate / (365 days * BORROW_TOKEN_PRECISION);

        // Airdrop the expected debt to the borrower
        airdrop(address(borrowToken), userBorrower, _newExpectedDebt);

        // Finally close the zombie trove
        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), _newExpectedDebt);
        troveManager.close_zombie_trove(_troveId);
        vm.stopPrank();

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E30");
        assertEq(_trove.collateral, 0, "E31");
        assertEq(_trove.annual_interest_rate, 0, "E32");
        assertEq(_trove.last_debt_update_time, 0, "E33");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E34");
        assertEq(_trove.owner, address(0), "E35");
        assertEq(_trove.pending_owner, address(0), "E36");
        assertEq(uint256(_trove.status), 4, "E37"); // Closed

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E38");
        assertEq(sortedTroves.size(), 0, "E39");
        assertEq(sortedTroves.first(), 0, "E40");
        assertEq(sortedTroves.last(), 0, "E41");
        assertFalse(sortedTroves.contains(_troveId), "E42");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E43");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E44");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _expectedCollateralAfterRedemption, "E45");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E46");
        assertGe(borrowToken.balanceOf(address(lender)), _newExpectedDebt, "E47");
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E48");

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), 0, 2, "E49");
        assertEq(troveManager.total_weighted_debt(), 0, "E50");
        assertEq(troveManager.collateral_balance(), 0, "E51");
        assertEq(troveManager.zombie_trove_id(), 0, "E52");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E53");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E54");
    }

    // // 1. lend
    // // 2. borrow all available liquidity
    // // 3. Pull liquidity to leave borrower with a zombie trove (and 0 debt)
    // // 4. close zombie trove
    function test_closeZombieTrove_zeroDebt(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

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
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E18");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E19");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
        assertEq(troveManager.zombie_trove_id(), 0, "E22");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

        // Expected profit is just the upfront fee
        uint256 _expectedProfit = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Pull all liquidity to make trove a zombie trove (with 0 debt)
        uint256 _amountToPull = _amount;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - ((_amount + _expectedProfit) * ORACLE_PRICE_SCALE / priceOracle.get_price());

        // Report profit
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = lender.report();

        // Check return Values
        assertEq(_profit, _expectedProfit, "E25");
        assertEq(_loss, 0, "E26");

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Pull liquidity from lender to make trove a zombie trove (with 0 debt)
        vm.startPrank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);
        vm.stopPrank();

        // Take the auction
        takeAuction(0);

        // Make sure lender got his funds
        assertApproxEqRel(borrowToken.balanceOf(address(userLender)), _amountToPull, 3e16, "E27"); // 3%. Slippage

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E28");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E29");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E30");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E31");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime, "E32");
        assertEq(_trove.owner, userBorrower, "E33");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E34");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E35");
        assertEq(sortedTroves.size(), 0, "E36");
        assertEq(sortedTroves.first(), 0, "E37");
        assertEq(sortedTroves.last(), 0, "E38");
        assertFalse(sortedTroves.contains(_troveId), "E39");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, "E40");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E41");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E42");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E43");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E44");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E45");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E46");
        assertEq(troveManager.total_weighted_debt(), 0, "E47");
        assertEq(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, "E48");
        assertEq(troveManager.zombie_trove_id(), 0, "E49");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E50");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E51");

        // Finally close the zombie trove
        vm.prank(userBorrower);
        troveManager.close_zombie_trove(_troveId);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E52");
        assertEq(_trove.collateral, 0, "E53");
        assertEq(_trove.annual_interest_rate, 0, "E54");
        assertEq(_trove.last_debt_update_time, 0, "E55");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E56");
        assertEq(_trove.owner, address(0), "E57");
        assertEq(_trove.pending_owner, address(0), "E58");
        assertEq(uint256(_trove.status), 4, "E59"); // Closed

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E60");
        assertEq(sortedTroves.size(), 0, "E61");
        assertEq(sortedTroves.first(), 0, "E62");
        assertEq(sortedTroves.last(), 0, "E63");
        assertFalse(sortedTroves.contains(_troveId), "E64");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E65");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E66");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _expectedCollateralAfterRedemption, "E67");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E68");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E69");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E70");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E71");
        assertEq(troveManager.total_weighted_debt(), 0, "E72");
        assertEq(troveManager.collateral_balance(), 0, "E73");
        assertEq(troveManager.zombie_trove_id(), 0, "E74");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E75");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E76");
    }

    function test_closeZombieTrove_notOwner(
        uint256 _amount,
        address _wrongUser
    ) public {
        vm.assume(_wrongUser != userBorrower);
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

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
        vm.startPrank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);
        vm.stopPrank();

        // Make sure trove is now a zombie trove
        assertEq(troveManager.zombie_trove_id(), _troveId, "E0");

        // Make sure non-owner cannot close trove
        vm.prank(_wrongUser);
        vm.expectRevert("!owner");
        troveManager.close_zombie_trove(_troveId);
    }

    function test_closeZombieTrove_notZombie(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure cannot zombie close trove that is not a zombie
        vm.prank(userBorrower);
        vm.expectRevert("!zombie");
        troveManager.close_zombie_trove(_troveId);
    }

}
