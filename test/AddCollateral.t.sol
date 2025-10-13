// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract AddCollateralTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_addCollateralToActiveTrove(uint256 _amount, uint256 _collateralAmountToAdd) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);
        _collateralAmountToAdd = bound(_collateralAmountToAdd, minFuzzAmount, maxFuzzAmount);

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
        assertEq(troveManager.zombie_trove_id(), 0, "E20");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E21");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E22");

        // Finally add collateral
        airdrop(address(collateralToken), userBorrower, _collateralAmountToAdd);
        vm.startPrank(userBorrower);
        collateralToken.approve(address(troveManager), _collateralAmountToAdd);
        troveManager.add_collateral(_troveId, _collateralAmountToAdd);
        vm.stopPrank();

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E23");
        assertEq(_trove.collateral, _collateralNeeded + _collateralAmountToAdd, "E24");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E25");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E26");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E27");
        assertEq(_trove.owner, userBorrower, "E28");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E29");
        assertGt(_trove.collateral * exchange.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO - 1e15, "E30");

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E31");
        assertEq(sortedTroves.size(), 1, "E32");
        assertEq(sortedTroves.first(), _troveId, "E33");
        assertEq(sortedTroves.last(), _troveId, "E34");
        assertTrue(sortedTroves.contains(_troveId), "E35");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded + _collateralAmountToAdd, "E36");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E37");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E38");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E39");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E40");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E41");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E42");
        assertEq(troveManager.collateral_balance(), _collateralNeeded + _collateralAmountToAdd, "E43");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E44");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E45");
    }

    // ------- @todo

    // function test_addCollateral_zeroCollateral
    // function test_addCollateral_toNonActiveTrove
    // function test_addCollateral_insufficientAllowance
    // function test_addCollateral_insufficientBalance
}