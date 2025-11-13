// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract LiquidateTests is Base {

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
    // 3. collateral price drops
    // 4. liquidate trove
    function test_liquidateTrove(
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
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E24");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E25");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E26");

        uint256 _priceBefore = priceOracle.price();

        // Drop collateral price to put trove below MCR
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracle.price.selector),
            abi.encode(_priceBefore / 2) // 50% drop
        );

        // Make sure price actually dropped
        assertEq(priceOracle.price(), _priceBefore / 2, "E27");

        // Calculate Trove's collateral ratio after price drop
        uint256 _troveCollateralRatioAfter = _trove.collateral * priceOracle.price() / _trove.debt;

        // Make sure Trove is below MCR
        assertLt(_troveCollateralRatioAfter, troveManager.MINIMUM_COLLATERAL_RATIO(), "E28");

        // Airdrop borrow tokens to the liquidator
        airdrop(address(borrowToken), liquidator, _expectedDebt);

        // Finally, liquidate the trove
        vm.startPrank(liquidator);
        borrowToken.approve(address(troveManager), _expectedDebt);
        troveManager.liquidate_trove(_troveId);
        vm.stopPrank();

        // Make sure lender got all the borrow tokens back
        assertEq(borrowToken.balanceOf(address(lender)), _expectedDebt, "E29");

        // Make sure liquidator got the collateral
        assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded, "E30");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E31");
        assertEq(_trove.collateral, 0, "E32");
        assertEq(_trove.annual_interest_rate, 0, "E33");
        assertEq(_trove.last_debt_update_time, 0, "E34");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E35");
        assertEq(_trove.owner, address(0), "E36");
        assertEq(_trove.pending_owner, address(0), "E37");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E38");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E39");
        assertEq(sortedTroves.size(), 0, "E40");
        assertEq(sortedTroves.first(), 0, "E41");
        assertEq(sortedTroves.last(), 0, "E42");
        assertFalse(sortedTroves.contains(_troveId), "E43");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E44");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E45");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E46");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E47");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E48");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E49");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E50");
        assertEq(troveManager.total_weighted_debt(), 0, "E51");
        assertEq(troveManager.collateral_balance(), 0, "E52");
        assertEq(troveManager.zombie_trove_id(), 0, "E53");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E54");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E55");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E56");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E57");
    }

    // // EXPECT REVERT -- clean this
    // // 1. lend
    // // 2. borrow all available liquidity
    // // 3. lender withdraws all liquidity, borrower ends up zombie with 0 debt
    // // 4. collateral price drops
    // // 5. liquidate trove?
    // function test_liquidateZombieTrove_zeroDebt(uint256 _amount) public {
    //     _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

    //     // Bump up interest rate so that's it's profitible to lend
    //     DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

    //     // Lend some from lender
    //     mintAndDepositIntoLender(userLender, _amount);

    //     assertEq(lender.totalAssets(), _amount, "E0");

    //     // Calculate how much collateral is needed for the borrow amount
    //     uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

    //     // Calculate expected debt (borrow amount + upfront fee)
    //     uint256 _upfrontFee = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
    //     uint256 _expectedDebt = _amount + _upfrontFee;

    //     // Open a trove
    //     uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

    //     // Check trove info
    //     ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
    //     assertEq(_trove.debt, _expectedDebt, "E1");
    //     assertEq(_trove.collateral, _collateralNeeded, "E2");
    //     assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E3");
    //     assertEq(_trove.last_debt_update_time, block.timestamp, "E4");
    //     assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E5");
    //     assertEq(_trove.owner, userBorrower, "E6"); // @todo pending_owner
    //     assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
    //     assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E8"); // 0.1%

    //     // Check sorted troves
    //     assertFalse(sortedTroves.empty(), "E9");
    //     assertEq(sortedTroves.size(), 1, "E10");
    //     assertEq(sortedTroves.first(), _troveId, "E11");
    //     assertEq(sortedTroves.last(), _troveId, "E12");
    //     assertTrue(sortedTroves.contains(_troveId), "E13");

    //     // Check balances
    //     assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E14");
    //     assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E15");
    //     assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E16");
    //     assertEq(borrowToken.balanceOf(address(lender)), 0, "E17");
    //     assertEq(borrowToken.balanceOf(userBorrower), _amount, "E18");

    //     // Check global info
    //     assertEq(troveManager.total_debt(), _expectedDebt, "E19");
    //     assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
    //     assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
    //     assertEq(troveManager.zombie_trove_id(), 0, "E22");

    //     // Check exchange is empty
    //     assertEq(borrowToken.balanceOf(address(exchange)), 0, "E23");
    //     assertEq(collateralToken.balanceOf(address(exchange)), 0, "E24");

    // // Check exchange route is empty
    // assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E26");
    // assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E27");

    //     // Report profit
    //     vm.prank(keeper);
    //     (uint256 _profit, uint256 _loss) = lender.report();

    //     // Check return Values
    //     assertEq(_profit, _upfrontFee, "E26");
    //     assertEq(_loss, 0, "E27");

    //     uint256 _balanceBefore = borrowToken.balanceOf(userLender);

    //     // Withdraw all funds
    //     vm.prank(userLender);
    //     lender.redeem(_amount, userLender, userLender);

    //     // Make sure lender got his money back minus slippage
    //     assertApproxEqRel(borrowToken.balanceOf(userLender), _balanceBefore + _amount, 3e16, "E28"); // 3%

    //     // Make sure borrower is zombie with 0 debt
    //     _trove = troveManager.troves(_troveId);
    //     assertEq(_trove.debt, 0, "E29");
    //     assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E30");

    //     uint256 _priceBefore = priceOracle.price();

    //     // Drop collateral price to put trove below MCR
    //     vm.mockCall(
    //         address(exchange),
    //         abi.encodeWithSelector(IExchange.price.selector),
    //         abi.encode(_priceBefore / 2) // 50% drop
    //     );

    //     // Make sure price actually dropped
    //     assertEq(priceOracle.price(), _priceBefore / 2, "E23");

    //     // Finally, liquidate the trove
    //     vm.startPrank(liquidator);
    //     // borrowToken.approve(address(troveManager), _expectedDebt);
    //     troveManager.liquidate_trove(_troveId);
    //     vm.stopPrank();
    // }


}
