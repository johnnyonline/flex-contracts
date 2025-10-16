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

        // Finally repay the trove back down to min debt
        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), _amountToRepay);
        troveManager.repay(_troveId, _amountToRepay);
        vm.stopPrank();

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt - _amountToRepay, "E22");
        assertEq(_trove.collateral, _collateralNeeded, "E23");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E24");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E25");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E26");
        assertEq(_trove.owner, userBorrower, "E27");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E28");
        assertGt(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E29");

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E30");
        assertEq(sortedTroves.size(), 1, "E31");
        assertEq(sortedTroves.first(), _troveId, "E32");
        assertEq(sortedTroves.last(), _troveId, "E33");
        assertTrue(sortedTroves.contains(_troveId), "E34");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E35");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E36");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E37");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E38");
        assertEq(borrowToken.balanceOf(address(lender)), _amountToRepay, "E39");
        assertEq(borrowToken.balanceOf(userBorrower), _amount - _amountToRepay, "E40");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt - _amountToRepay, "E41");
        assertEq(
            troveManager.total_weighted_debt(), (_expectedDebt - _amountToRepay) * DEFAULT_ANNUAL_INTEREST_RATE, "E42"
        );
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E43");
        assertEq(troveManager.zombie_trove_id(), 0, "E44");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E45");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E46");
    }

    function test_repay_zeroAmount(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

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
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

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
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

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
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

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
