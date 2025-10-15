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
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

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
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(
            _trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E7"
        ); // 0.1%

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
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E18");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E19");
        assertEq(troveManager.zombie_trove_id(), 0, "E20");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E21");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E22");

        // Pull enough liquidity to make trove a zombie trove (but above 0 debt)
        uint256 _amountToPull = _amount - 100 ether;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_amountToPull * 1e18 / exchange.price());

        // Pull liquidity from lender to make trove a zombie trove (but above 0 debt)
        vm.startPrank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);
        vm.stopPrank();

        // Do some intermediate checks on lender
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E23");
        assertApproxEqRel(borrowToken.balanceOf(address(userLender)), _amountToPull, 3e16, "E24"); // 3%. Slippage

        // Do some intermediate checks on borrower
        _trove = troveManager.troves(_troveId);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E25");
        assertEq(_trove.debt, _expectedDebt - _amountToPull, "E26");
        assertEq(troveManager.zombie_trove_id(), _troveId, "E27");

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
        assertEq(_trove.debt, 0, "E28");
        assertEq(_trove.collateral, 0, "E29");
        assertEq(_trove.annual_interest_rate, 0, "E30");
        assertEq(_trove.last_debt_update_time, 0, "E31");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E32");
        assertEq(_trove.owner, address(0), "E33");
        assertEq(uint256(_trove.status), 4, "E34"); // Closed

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E35");
        assertEq(sortedTroves.size(), 0, "E36");
        assertEq(sortedTroves.first(), 0, "E37");
        assertEq(sortedTroves.last(), 0, "E38");
        assertFalse(sortedTroves.contains(_troveId), "E39");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E40");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E41");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _expectedCollateralAfterRedemption, "E42");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E43");
        assertGe(borrowToken.balanceOf(address(lender)), _newExpectedDebt, "E44");
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E45");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E46");
        assertEq(troveManager.total_weighted_debt(), 0, "E47");
        assertEq(troveManager.collateral_balance(), 0, "E48");
        assertEq(troveManager.zombie_trove_id(), 0, "E49");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E50");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E51");
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
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

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
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E6");
        assertApproxEqRel(
            _trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E7"
        ); // 0.1%

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
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E18");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E19");
        assertEq(troveManager.zombie_trove_id(), 0, "E20");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E21");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E22");

        // Expected profit is just the upfront fee
        uint256 _expectedProfit = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Pull all liquidity to make trove a zombie trove (with 0 debt)
        uint256 _amountToPull = _amount;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption =
            _collateralNeeded - ((_amount + _expectedProfit) * 1e18 / exchange.price());

        // Report profit
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = lender.report();

        // Check return Values
        assertEq(_profit, _expectedProfit, "E23");
        assertEq(_loss, 0, "E24");

        // Pull liquidity from lender to make trove a zombie trove (with 0 debt)
        vm.startPrank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);
        vm.stopPrank();

        // Make sure lender got his funds
        assertApproxEqRel(borrowToken.balanceOf(address(userLender)), _amountToPull, 3e16, "E25"); // 3%. Slippage

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E26");
        assertEq(_trove.collateral, _expectedCollateralAfterRedemption, "E27");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E28");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E29");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E30");
        assertEq(_trove.owner, userBorrower, "E31");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E32");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E33");
        assertEq(sortedTroves.size(), 0, "E34");
        assertEq(sortedTroves.first(), 0, "E35");
        assertEq(sortedTroves.last(), 0, "E36");
        assertFalse(sortedTroves.contains(_troveId), "E37");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, "E38");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E39");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E40");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E41");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E42");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E43");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E44");
        assertEq(troveManager.total_weighted_debt(), 0, "E45");
        assertEq(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, "E46");
        assertEq(troveManager.zombie_trove_id(), 0, "E47");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E48");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E49");

        // Finally close the zombie trove
        vm.prank(userBorrower);
        troveManager.close_zombie_trove(_troveId);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E50");
        assertEq(_trove.collateral, 0, "E51");
        assertEq(_trove.annual_interest_rate, 0, "E52");
        assertEq(_trove.last_debt_update_time, 0, "E53");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E54");
        assertEq(_trove.owner, address(0), "E55");
        assertEq(uint256(_trove.status), 4, "E56"); // Closed

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E57");
        assertEq(sortedTroves.size(), 0, "E58");
        assertEq(sortedTroves.first(), 0, "E59");
        assertEq(sortedTroves.last(), 0, "E60");
        assertFalse(sortedTroves.contains(_troveId), "E61");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E62");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E63");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _expectedCollateralAfterRedemption, "E64");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E65");
        assertGe(borrowToken.balanceOf(address(lender)), 0, "E66");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E67");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E68");
        assertEq(troveManager.total_weighted_debt(), 0, "E69");
        assertEq(troveManager.collateral_balance(), 0, "E70");
        assertEq(troveManager.zombie_trove_id(), 0, "E71");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E72");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E73");
    }

}
