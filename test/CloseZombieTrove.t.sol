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
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E18");

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

        // Pull enough liquidity to make trove a zombie trove (but above 0 debt)
        uint256 _amountToPull = _amount - 100 ether;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_amountToPull * 1e18 / priceOracle.price());

        // Pull liquidity from lender to make trove a zombie trove (but above 0 debt)
        vm.startPrank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);
        vm.stopPrank();

        // Do some intermediate checks on lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E27");
        assertApproxEqRel(borrowToken.balanceOf(address(userLender)), _amountToPull, 3e16, "E28"); // 3%. Slippage

        // Do some intermediate checks on borrower
        _trove = troveManager.troves(_troveId);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E29");
        assertEq(_trove.debt, _expectedDebt - _amountToPull, "E30");
        assertEq(troveManager.zombie_trove_id(), _troveId, "E31");

        uint256 _newExpectedDebt = _expectedDebt - _amountToPull;

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
        assertEq(_trove.debt, 0, "E32");
        assertEq(_trove.collateral, 0, "E33");
        assertEq(_trove.annual_interest_rate, 0, "E34");
        assertEq(_trove.last_debt_update_time, 0, "E35");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E36");
        assertEq(_trove.owner, address(0), "E37");
        assertEq(_trove.pending_owner, address(0), "E38");
        assertEq(uint256(_trove.status), 4, "E39"); // Closed

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E40");
        assertEq(sortedTroves.size(), 0, "E41");
        assertEq(sortedTroves.first(), 0, "E42");
        assertEq(sortedTroves.last(), 0, "E43");
        assertFalse(sortedTroves.contains(_troveId), "E44");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E45");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E46");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _expectedCollateralAfterRedemption, "E47");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E48");
        assertGe(borrowToken.balanceOf(address(lender)), _newExpectedDebt, "E49");
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E50");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E51");
        assertEq(troveManager.total_weighted_debt(), 0, "E52");
        assertEq(troveManager.collateral_balance(), 0, "E53");
        assertEq(troveManager.zombie_trove_id(), 0, "E54");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E55");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E56");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E57");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E58");
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
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E18");

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

        // Expected profit is just the upfront fee
        uint256 _expectedProfit = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Pull all liquidity to make trove a zombie trove (with 0 debt)
        uint256 _amountToPull = _amount;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - ((_amount + _expectedProfit) * 1e18 / priceOracle.price());

        // Report profit
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = lender.report();

        // Check return Values
        assertEq(_profit, _expectedProfit, "E27");
        assertEq(_loss, 0, "E28");

        // Pull liquidity from lender to make trove a zombie trove (with 0 debt)
        vm.startPrank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);
        vm.stopPrank();

        // Make sure lender got his funds
        assertApproxEqRel(borrowToken.balanceOf(address(userLender)), _amountToPull, 3e16, "E29"); // 3%. Slippage

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E30");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E31");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E32");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E33");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E34");
        assertEq(_trove.owner, userBorrower, "E35");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E36");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E37");
        assertEq(sortedTroves.size(), 0, "E38");
        assertEq(sortedTroves.first(), 0, "E39");
        assertEq(sortedTroves.last(), 0, "E40");
        assertFalse(sortedTroves.contains(_troveId), "E41");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, "E42");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E43");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E44");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E45");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E46");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E47");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E48");
        assertEq(troveManager.total_weighted_debt(), 0, "E49");
        assertEq(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, "E50");
        assertEq(troveManager.zombie_trove_id(), 0, "E51");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E52");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E53");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E54");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E55");

        // Finally close the zombie trove
        vm.prank(userBorrower);
        troveManager.close_zombie_trove(_troveId);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E56");
        assertEq(_trove.collateral, 0, "E57");
        assertEq(_trove.annual_interest_rate, 0, "E58");
        assertEq(_trove.last_debt_update_time, 0, "E59");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E60");
        assertEq(_trove.owner, address(0), "E61");
        assertEq(_trove.pending_owner, address(0), "E62");
        assertEq(uint256(_trove.status), 4, "E63"); // Closed

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E64");
        assertEq(sortedTroves.size(), 0, "E65");
        assertEq(sortedTroves.first(), 0, "E66");
        assertEq(sortedTroves.last(), 0, "E67");
        assertFalse(sortedTroves.contains(_troveId), "E68");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E69");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E70");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _expectedCollateralAfterRedemption, "E71");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E72");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E73");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E74");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E75");
        assertEq(troveManager.total_weighted_debt(), 0, "E76");
        assertEq(troveManager.collateral_balance(), 0, "E77");
        assertEq(troveManager.zombie_trove_id(), 0, "E78");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E79");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E80");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E81");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E82");
    }

}
