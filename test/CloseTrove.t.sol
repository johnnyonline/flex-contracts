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
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E7"
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
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E19");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E20");
        assertEq(troveManager.zombie_trove_id(), 0, "E21");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E22");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E23");

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
        assertEq(_trove.debt, 0, "E24");
        assertEq(_trove.collateral, 0, "E25");
        assertEq(_trove.annual_interest_rate, 0, "E26");
        assertEq(_trove.last_debt_update_time, 0, "E27");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E28");
        assertEq(_trove.owner, address(0), "E29");
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

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E46");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E47");
    }

    function test_closeTrove_notOwner(
        uint256 _amount,
        address _wrongUser
    ) public {
        vm.assume(_wrongUser != userBorrower);
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure non-owner cannot close trove
        vm.prank(_wrongUser);
        vm.expectRevert("!owner");
        troveManager.close_trove(_troveId);
    }

    function test_closeTrove_notActive(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Pull enough liquidity to make trove a zombie trove (but above 0 debt)
        uint256 _amountToPull = _amount - 100 * BORROW_TOKEN_PRECISION;

        // Pull liquidity from lender to make trove a zombie trove (but above 0 debt)
        vm.startPrank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);
        vm.stopPrank();

        // Make sure trove is now a zombie trove
        assertEq(troveManager.zombie_trove_id(), _troveId, "E0");

        // Make sure cannot close trove again since it's not active
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.close_trove(_troveId);
    }

    function test_closeTrove_approvedOperator(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Approve operator
        vm.prank(userBorrower);
        troveManager.approve(operator, true);

        // Airdrop borrow tokens to operator to repay
        uint256 _debt = troveManager.get_trove_debt_after_interest(_troveId);
        airdrop(address(borrowToken), operator, _debt);

        // Operator closes the trove
        vm.startPrank(operator);
        borrowToken.approve(address(troveManager), _debt);
        troveManager.close_trove(_troveId);
        vm.stopPrank();

        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.closed), "E0");
    }

    function test_closeTrove_unapprovedOperator_reverts(
        uint256 _amount,
        address _caller
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);
        vm.assume(_caller != userBorrower);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        vm.prank(_caller);
        vm.expectRevert("!owner");
        troveManager.close_trove(_troveId);
    }

}
