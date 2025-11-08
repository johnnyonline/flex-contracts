// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract LendTests is Base {

    function setUp() public override {
        Base.setUp();

        // Set `profitMaxUnlockTime` to 0
        vm.prank(management);
        lender.setProfitMaxUnlockTime(0);

        // Set fees to 0
        vm.prank(management);
        lender.setPerformanceFee(0);

        // Limit fuzz amount to decrease slippage
        maxFuzzAmount = 10_000 ether;
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip some time, check we earn interest
    // 4. withdraw everything (+ profit)
    function test_lend(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        assertEq(lender.totalAssets(), _amount, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _upfrontFee = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedDebt = _amount + _upfrontFee;

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E1");
        assertEq(_trove.collateral, _collateralNeeded, "E2");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E3");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E4");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E5");
        assertEq(_trove.owner, userBorrower, "E6");
        assertEq(_trove.pending_owner, address(0), "E7");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E8");
        assertApproxEqRel(
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E9"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E10");
        assertEq(sortedTroves.size(), 1, "E11");
        assertEq(sortedTroves.first(), _troveId, "E12");
        assertEq(sortedTroves.last(), _troveId, "E13");
        assertTrue(sortedTroves.contains(_troveId), "E14");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E15");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E16");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E17");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E18");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E19");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E20");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E21");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E22");
        assertEq(troveManager.zombie_trove_id(), 0, "E23");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E24");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E25");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E26");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E27");

        // Skip some time, calculate expected interest
        uint256 _daysToSkip = 90 days;
        uint256 _expectedProfit =
            _upfrontFee + _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * _daysToSkip / 365 days / 1e18;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption =
            _collateralNeeded - ((_amount + _expectedProfit) * 1e18 / priceOracle.price());

        // Sanity check
        assertGt(_expectedProfit, 0, "E28");

        // Earn Interest
        skip(_daysToSkip);

        // Report profit
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = lender.report();

        // Check return Values
        assertEq(_profit, _expectedProfit, "E29");
        assertEq(_loss, 0, "E30");

        uint256 _balanceBefore = borrowToken.balanceOf(userLender);

        // Withdraw all funds
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // profit > slippage
        assertGt(borrowToken.balanceOf(userLender), _balanceBefore + _amount, "E31");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E32");
        assertApproxEqRel(_trove.collateral, _expectedCollateralAfterRedemption, 5e15, "E33"); // 0.5%
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E34");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E35");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp - _daysToSkip, "E36");
        assertEq(_trove.owner, userBorrower, "E37");
        assertEq(_trove.pending_owner, address(0), "E38");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E39");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E40");
        assertEq(sortedTroves.size(), 0, "E41");
        assertEq(sortedTroves.first(), 0, "E42");
        assertEq(sortedTroves.last(), 0, "E43");
        assertFalse(sortedTroves.contains(_troveId), "E44");

        // Check balances
        assertApproxEqRel(
            collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, 5e15, "E45"
        ); // 0.5%
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E46");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E47");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E48");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E49");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E50");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E51");
        assertEq(troveManager.total_weighted_debt(), 0, "E52");
        assertApproxEqRel(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, 5e15, "E53"); // 0.5%
        assertEq(troveManager.zombie_trove_id(), 0, "E54");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E55");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E56");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E57");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E58");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip some time, check we earn interest
    // 4. withdraw without reporting, so borrower has tiny amount of debt left (< min debt)
    // 5. make sure borrower is now zombie and has tiny debt left
    function test_lend_noReport(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        assertEq(lender.totalAssets(), _amount, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _upfrontFee = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedDebt = _amount + _upfrontFee;

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E1");
        assertEq(_trove.collateral, _collateralNeeded, "E2");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E3");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E4");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E5");
        assertEq(_trove.owner, userBorrower, "E6");
        assertEq(_trove.pending_owner, address(0), "E7");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E8");
        assertApproxEqRel(
            _trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E9"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E10");
        assertEq(sortedTroves.size(), 1, "E11");
        assertEq(sortedTroves.first(), _troveId, "E12");
        assertEq(sortedTroves.last(), _troveId, "E13");
        assertTrue(sortedTroves.contains(_troveId), "E14");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E15");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E16");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E17");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E18");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E19");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E20");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E21");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E22");
        assertEq(troveManager.zombie_trove_id(), 0, "E23");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E24");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E25");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E26");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E27");

        // Skip some time, calculate expected interest
        uint256 _daysToSkip = 90 days;
        uint256 _expectedProfit =
            _upfrontFee + _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * _daysToSkip / 365 days / 1e18;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_amount * 1e18 / priceOracle.price());

        // Sanity check
        assertGt(_expectedProfit, 0, "E28");

        // Earn Interest
        skip(_daysToSkip);

        uint256 _balanceBefore = borrowToken.balanceOf(userLender);

        // Withdraw all funds
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // No report, no profit, loss bc slippage
        assertLt(borrowToken.balanceOf(userLender), _balanceBefore + _amount, "E29");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedProfit, "E30");
        assertApproxEqRel(_trove.collateral, _expectedCollateralAfterRedemption, 5e15, "E31"); // 0.5%
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E32");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E33");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp - _daysToSkip, "E34");
        assertEq(_trove.owner, userBorrower, "E35");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E36");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E37");
        assertEq(sortedTroves.size(), 0, "E38");
        assertEq(sortedTroves.first(), 0, "E39");
        assertEq(sortedTroves.last(), 0, "E40");
        assertFalse(sortedTroves.contains(_troveId), "E41");

        // Check balances
        assertApproxEqRel(
            collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, 5e15, "E42"
        ); // 0.5%
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E43");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E44");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E45");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E46");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E47");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedProfit, "E48");
        assertEq(troveManager.total_weighted_debt(), _expectedProfit * DEFAULT_ANNUAL_INTEREST_RATE, "E49");
        assertApproxEqRel(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, 5e15, "E50"); // 0.5%
        assertEq(troveManager.zombie_trove_id(), _troveId, "E51");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E52");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E53");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E54");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E55");
    }

}
