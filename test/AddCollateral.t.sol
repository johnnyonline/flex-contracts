// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract AddCollateralTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_addCollateralToActiveTrove(
        uint256 _amount,
        uint256 _collateralAmountToAdd
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);
        _collateralAmountToAdd = bound(_collateralAmountToAdd, minFuzzAmount, maxFuzzAmount);

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

        // Finally add collateral
        airdrop(address(collateralToken), userBorrower, _collateralAmountToAdd);
        vm.startPrank(userBorrower);
        collateralToken.approve(address(troveManager), _collateralAmountToAdd);
        troveManager.add_collateral(_troveId, _collateralAmountToAdd);
        vm.stopPrank();

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E24");
        assertEq(_trove.collateral, _collateralNeeded + _collateralAmountToAdd, "E25");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E26");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E27");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E28");
        assertEq(_trove.owner, userBorrower, "E29");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E30");
        assertGt(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO * 999 / 1000, // Decrease by 0.1%
            "E31"
        );

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E32");
        assertEq(sortedTroves.size(), 1, "E33");
        assertEq(sortedTroves.first(), _troveId, "E34");
        assertEq(sortedTroves.last(), _troveId, "E35");
        assertTrue(sortedTroves.contains(_troveId), "E36");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded + _collateralAmountToAdd, "E37");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E38");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E39");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E40");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E41");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E42");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E43");
        assertEq(troveManager.collateral_balance(), _collateralNeeded + _collateralAmountToAdd, "E44");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E45");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E46");
    }

    function test_addCollateral_zeroCollateral(
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

        // Try to add zero collateral
        vm.startPrank(userBorrower);
        vm.expectRevert("!collateral_amount");
        troveManager.add_collateral(_troveId, 0);
        vm.stopPrank();
    }

    function test_addCollateral_notOwner(
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

        // Try to add collateral from another user
        vm.prank(anotherUserBorrower);
        vm.expectRevert("!owner");
        troveManager.add_collateral(_troveId, minFuzzAmount);
    }

    function test_addCollateral_notActive(
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
        vm.prank(userLender);
        lender.redeem(_amountToPull, userLender, userLender);

        // Make sure trove is a zombie trove
        assertEq(uint256(troveManager.troves(_troveId).status), uint256(ITroveManager.Status.zombie), "E0");

        // Try to add collateral to a non-active trove
        vm.prank(userBorrower);
        vm.expectRevert("!active");
        troveManager.add_collateral(_troveId, _amount);
    }

    function test_addCollateral_approvedOperator(
        uint256 _amount,
        uint256 _collateralAmountToAdd
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);
        _collateralAmountToAdd = bound(_collateralAmountToAdd, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Approve operator
        vm.prank(userBorrower);
        troveManager.approve(operator, true);

        // Operator adds collateral
        airdrop(address(collateralToken), operator, _collateralAmountToAdd);
        vm.startPrank(operator);
        collateralToken.approve(address(troveManager), _collateralAmountToAdd);
        troveManager.add_collateral(_troveId, _collateralAmountToAdd);
        vm.stopPrank();

        assertEq(troveManager.troves(_troveId).collateral, _collateralNeeded + _collateralAmountToAdd, "E0");
    }

    function test_addCollateral_unapprovedOperator_reverts(
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
        troveManager.add_collateral(_troveId, minFuzzAmount);
    }

}
