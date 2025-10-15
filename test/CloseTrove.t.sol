// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract CloseTroveTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. close trove
    function test_closeTrove(
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

        // Airdrop the the expected debt to the borrower
        airdrop(address(borrowToken), userBorrower, _expectedDebt);

        // Finally close the trove
        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), _expectedDebt);
        troveManager.close_trove(_troveId);
        vm.stopPrank();

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E23");
        assertEq(_trove.collateral, 0, "E24");
        assertEq(_trove.annual_interest_rate, 0, "E25");
        assertEq(_trove.last_debt_update_time, 0, "E26");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E27");
        assertEq(_trove.owner, address(0), "E28");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.closed), "E30");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E31");
        assertEq(sortedTroves.size(), 0, "E32");
        assertEq(sortedTroves.first(), 0, "E33");
        assertEq(sortedTroves.last(), 0, "E34");
        assertFalse(sortedTroves.contains(_troveId), "E35");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E36");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E37");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _collateralNeeded, "E38");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E39");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E40");
        assertEq(borrowToken.balanceOf(userBorrower), 0, "E41");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E42");
        assertEq(troveManager.total_weighted_debt(), 0, "E43");
        assertEq(troveManager.collateral_balance(), 0, "E44");
        assertEq(troveManager.zombie_trove_id(), 0, "E45");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchange)), 0, "E46");
        assertEq(collateralToken.balanceOf(address(exchange)), 0, "E47");
    }

}
