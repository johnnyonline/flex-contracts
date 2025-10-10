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
    function test_lend(uint256 _amount) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        assertEq(lender.totalAssets(), _amount, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _upfrontFee = troveManager.calculate_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
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
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E8"); // 0.1%

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

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E22");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E23");

        // Skip some time, calculate expected interest
        uint256 _daysToSkip = 90 days;
        uint256 _expectedProfit = _upfrontFee + _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * _daysToSkip / 365 days / 1e18;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - ((_amount + _expectedProfit) * 1e18 / exchange.price());

        // Sanity check
        assertGt(_expectedProfit, 0, "E24");

        // Earn Interest
        skip(_daysToSkip);

        // Report profit
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = lender.report();

        // Check return Values
        assertEq(_profit, _expectedProfit, "E24");
        assertEq(_loss, 0, "E25");

        uint256 _balanceBefore = borrowToken.balanceOf(userLender);

        // Withdraw all funds
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // profit > slippage
        assertGt(borrowToken.balanceOf(userLender), _balanceBefore + _amount, "E26");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E27");
        assertApproxEqRel(_trove.collateral, _expectedCollateralAfterRedemption, 5e15, "E28"); // 0.5%
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E29");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp - _daysToSkip, "E31");
        assertEq(_trove.owner, userBorrower, "E32");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.fully_redeemed), "E33");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E30");
        assertEq(sortedTroves.size(), 0, "E31");
        assertEq(sortedTroves.first(), 0, "E32");
        assertEq(sortedTroves.last(), 0, "E33");
        assertFalse(sortedTroves.contains(_troveId), "E34");

        // Check balances
        assertApproxEqRel(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, 5e15, "E35"); // 0.5%
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E36");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E37");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E38");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E39");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E40");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E41");
        assertEq(troveManager.total_weighted_debt(), 0, "E42");
        assertApproxEqRel(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, 5e15, "E43"); // 0.5%

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E44");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E45");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip some time, check we earn interest
    // 4. withdraw without reporting, so borrower has tiny amount of debt left (< min debt)
    // 5. use flashloan to get around it?
    function test_lend_idk(uint256 _amount) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        assertEq(lender.totalAssets(), _amount, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _upfrontFee = troveManager.calculate_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
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
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E8"); // 0.1%

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

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E22");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E23");

        // Skip some time, calculate expected interest
        uint256 _daysToSkip = 90 days;
        uint256 _expectedProfit = _upfrontFee + _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * _daysToSkip / 365 days / 1e18;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - ((_amount + _expectedProfit) * 1e18 / exchange.price());

        // Sanity check
        assertGt(_expectedProfit, 0, "E24");

        // Earn Interest
        skip(_daysToSkip);

        // Since we don't report, lender tries to withdraw less than full amount, so borrower has tiny amount of debt left (< min debt)
        vm.prank(userLender);
        vm.expectRevert(bytes("!trove_new_debt"));
        lender.redeem(_amount, userLender, userLender);

        uint256 _balanceBefore = borrowToken.balanceOf(userLender);

        // // Withdraw up to min debt
        // uint256 _firstRedeemAmount = _amount - troveManager.MIN_DEBT();
        // if (_firstRedeemAmount > 0) {
        //     vm.prank(userLender);
        //     lender.redeem(_firstRedeemAmount, userLender, userLender);
        // }

        // // Borrow to redeem first borrower
        // uint256 _troveId = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // // Repay

        // // Withdraw all funds
        // // vm.prank(userLender);
        // // lender.redeem(_firstRedeemAmount, userLender, userLender);

        // // profit > slippage
        // assertGt(borrowToken.balanceOf(userLender), _balanceBefore + _amount, "E26");

        // // Check everything again

        // // Check trove info
        // _trove = troveManager.troves(_troveId);
        // assertEq(_trove.debt, 0, "E27");
        // assertApproxEqRel(_trove.collateral, _expectedCollateralAfterRedemption, 5e15, "E28"); // 0.5%
        // assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E29");
        // assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        // assertEq(_trove.last_interest_rate_adj_time, block.timestamp - _daysToSkip, "E31");
        // assertEq(_trove.owner, userBorrower, "E32");
        // assertEq(uint256(_trove.status), uint256(ITroveManager.Status.fully_redeemed), "E33");

        // // Check sorted troves
        // assertTrue(sortedTroves.empty(), "E30");
        // assertEq(sortedTroves.size(), 0, "E31");
        // assertEq(sortedTroves.first(), 0, "E32");
        // assertEq(sortedTroves.last(), 0, "E33");
        // assertFalse(sortedTroves.contains(_troveId), "E34");

        // // Check balances
        // assertApproxEqRel(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, 5e15, "E35"); // 0.5%
        // assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E36");
        // assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E37");
        // assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E38");
        // assertEq(borrowToken.balanceOf(address(lender)), 0, "E39");
        // assertEq(borrowToken.balanceOf(userBorrower), _amount, "E40");

        // // Check global info
        // assertEq(troveManager.total_debt(), 0, "E41");
        // assertEq(troveManager.total_weighted_debt(), 0, "E42");
        // assertApproxEqRel(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, 5e15, "E43"); // 0.5%

        // // Check exchange is empty
        // assertEq(borrowToken.balanceOf(address(exchange)), 0, "E44");
        // assertEq(collateralToken.balanceOf(address(exchange)), 0, "E45");
    }




    // // 1. lend
    // // 2. borrow very little so that upfront fee is lower than slippage
    // // 3. withdraw everything immediately, show there's loss on slippage
    // function test_lend_withdrawImmediately(uint256 _amount) public {
}