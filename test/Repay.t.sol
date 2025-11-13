// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract RepayTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. repay up to min debt
    function test_repay(
        uint256 _amount,
        uint256 _amountToRepay
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 150 / 100, maxFuzzAmount); // At least 50% above min debt so we have something to repay
        _amountToRepay = bound(_amountToRepay, _amount / 100, _amount - troveManager.MIN_DEBT()); // Make sure we leave at least min debt

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

        // Finally repay the trove back down to min debt
        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), _amountToRepay);
        troveManager.repay(_troveId, _amountToRepay);
        vm.stopPrank();

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt - _amountToRepay, "E27");
        assertEq(_trove.collateral, _collateralNeeded, "E28");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E29");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E31");
        assertEq(_trove.owner, userBorrower, "E32");
        assertEq(_trove.pending_owner, address(0), "E33");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E34");
        assertGt(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E35");

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E36");
        assertEq(sortedTroves.size(), 1, "E37");
        assertEq(sortedTroves.first(), _troveId, "E38");
        assertEq(sortedTroves.last(), _troveId, "E39");
        assertTrue(sortedTroves.contains(_troveId), "E40");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E41");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E42");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E43");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E44");
        assertEq(borrowToken.balanceOf(address(lender)), _amountToRepay, "E45");
        assertEq(borrowToken.balanceOf(userBorrower), _amount - _amountToRepay, "E46");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt - _amountToRepay, "E47");
        assertEq(troveManager.total_weighted_debt(), (_expectedDebt - _amountToRepay) * DEFAULT_ANNUAL_INTEREST_RATE, "E48");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E49");
        assertEq(troveManager.zombie_trove_id(), 0, "E50");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E51");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E52");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E53");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E54");
    }

    function test_repay_zeroAmount(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to repay with 0 amount
        vm.prank(userBorrower);
        vm.expectRevert("!debt_amount");
        troveManager.repay(_troveId, 0);
    }

    function test_repay_notOwner(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to repay from another user
        vm.prank(anotherUserBorrower);
        vm.expectRevert("!owner");
        troveManager.repay(_troveId, _amount);
    }

    function test_repay_troveNotActive(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Pull enough liquidity to make trove a zombie trove (but above 0 debt)
        uint256 _amountToPull = _amount - 100 ether;

        // Pull liquidity from lender to make trove a zombie trove (but above 0 debt)
        vm.prank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);

        // Make sure trove is a zombie trove
        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.zombie), "E25");

        // Try to repay a non-active trove
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.repay(_troveId, _amount);
    }

    function test_repay_amountScalesDownToMinDebt(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 150 / 100, maxFuzzAmount); // At least 50% above min debt so we have something to repay

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Finally repay the trove back down to min debt
        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), type(uint256).max);
        troveManager.repay(_troveId, type(uint256).max); // Use max uint256 to trigger scaling down to min debt
        vm.stopPrank();

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, troveManager.MIN_DEBT(), "E0");
    }

}
