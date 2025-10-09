// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract RemoveCollateralTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_removeCollateralFromActiveTrove(uint256 _amount, uint256 _collateralToRemove) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / exchange.price();

        // Make sure we don't try to remove too much collateral
        uint256 _maxCollateralToRemove = _collateralNeeded - (_amount * troveManager.MINIMUM_COLLATERAL_RATIO() / exchange.price());

        // Decrease a touch
        _maxCollateralToRemove = _maxCollateralToRemove * 99 / 100;

        // Bound collateral to remove
        _collateralToRemove = bound(_collateralToRemove, 1, _maxCollateralToRemove);

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _amount + troveManager.calculate_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

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
        assertApproxEqRel(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E7"); // 0.1%

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

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E20");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E21");

        // Finally remove collateral
        vm.prank(userBorrower);
        troveManager.remove_collateral(_troveId, _collateralToRemove);

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E22");
        assertEq(_trove.collateral, _collateralNeeded - _collateralToRemove, "E23");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E24");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E25");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E26");
        assertEq(_trove.owner, userBorrower, "E27");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E28");
        assertLt(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, "E29");

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E30");
        assertEq(sortedTroves.size(), 1, "E31");
        assertEq(sortedTroves.first(), _troveId, "E32");
        assertEq(sortedTroves.last(), _troveId, "E33");
        assertTrue(sortedTroves.contains(_troveId), "E34");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded - _collateralToRemove, "E35");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E36");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _collateralToRemove, "E37");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E38");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E39");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E40");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E41");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E42");
        assertEq(troveManager.collateral_balance(), _collateralNeeded - _collateralToRemove, "E43");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E44");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E45");
    }

    // ------- @todo

    // function test_removeCollateral_zeroCollateral
    // function test_removeCollateral_troveNotActive
    // function test_removeCollateral_insufficientCollateralInTrove
    // function test_removeCollateral_belowMCR
}