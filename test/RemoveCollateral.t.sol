// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract RemoveCollateralTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_removeCollateralFromActiveTrove(
        uint256 _amount,
        uint256 _collateralToRemove
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Make sure we don't try to remove too much collateral
        uint256 _maxCollateralToRemove = _collateralNeeded - (_amount * troveManager.MINIMUM_COLLATERAL_RATIO() / priceOracle.price());

        // Decrease a touch
        _maxCollateralToRemove = _maxCollateralToRemove * 99 / 100;

        // Bound collateral to remove
        _collateralToRemove = bound(_collateralToRemove, 1, _maxCollateralToRemove);

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

        // Finally remove collateral
        vm.prank(userBorrower);
        troveManager.remove_collateral(_troveId, _collateralToRemove);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E27");
        assertEq(_trove.collateral, _collateralNeeded - _collateralToRemove, "E28");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E29");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E31");
        assertEq(_trove.owner, userBorrower, "E32");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E33");
        assertLt(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E34");

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E35");
        assertEq(sortedTroves.size(), 1, "E36");
        assertEq(sortedTroves.first(), _troveId, "E37");
        assertEq(sortedTroves.last(), _troveId, "E38");
        assertTrue(sortedTroves.contains(_troveId), "E39");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded - _collateralToRemove, "E40");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E41");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _collateralToRemove, "E42");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E43");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E44");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E45");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E46");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E47");
        assertEq(troveManager.collateral_balance(), _collateralNeeded - _collateralToRemove, "E48");
        assertEq(troveManager.zombie_trove_id(), 0, "E49");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E50");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E51");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E52");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E53");
    }

    function test_removeCollateral_zeroCollateral(
        uint256 _troveId
    ) public {
        vm.prank(userBorrower);
        vm.expectRevert("!collateral_amount");
        troveManager.remove_collateral(_troveId, 0);
    }

    function test_removeCollateral_notOwner(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to remove collateral as a different user
        vm.prank(anotherUserBorrower);
        vm.expectRevert("!owner");
        troveManager.remove_collateral(_troveId, minFuzzAmount);
    }

    function test_removeCollateral_troveNotActive(
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

        // Try to remove collateral from a non-active trove
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.remove_collateral(_troveId, _amount);
    }

    function test_removeCollateral_insufficientCollateralInTrove(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Try to remove more collateral than is in the trove
        vm.prank(userBorrower);
        vm.expectRevert("!trove.collateral");
        troveManager.remove_collateral(_troveId, _collateralNeeded + 1);
    }

    function test_removeCollateral_belowMCR(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate the minimum collateral to leave in the trove to stay above MCR
        uint256 _minCollateralToLeave = (_amount * troveManager.MINIMUM_COLLATERAL_RATIO()) / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate the maximum collateral that can be removed
        uint256 _maxCollateralToRemove = _collateralNeeded - _minCollateralToLeave;

        // Try to remove more collateral than is in the trove
        vm.prank(userBorrower);
        vm.expectRevert("!MINIMUM_COLLATERAL_RATIO");
        troveManager.remove_collateral(_troveId, _maxCollateralToRemove);
    }

}
