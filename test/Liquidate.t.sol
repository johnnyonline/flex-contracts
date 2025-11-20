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
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E24");

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
        borrowToken.approve(address(liquidationHandler), _expectedDebt);
        uint256[MAX_LIQUIDATION_BATCH_SIZE] memory _troveIdsToLiquidate;
        _troveIdsToLiquidate[0] = _troveId;
        troveManager.liquidate_troves(_troveIdsToLiquidate);
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
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E54");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E55");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E56");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E57");

        // Check liquidation handler is empty
        assertEq(borrowToken.balanceOf(address(liquidationHandler)), 0, "E58");
        assertEq(collateralToken.balanceOf(address(liquidationHandler)), 0, "E59");
    }

    // 1. lend
    // 2. borrow half of available liquidity from 1st borrower
    // 3. borrow half of available liquidity from 2nd borrower
    // 4. collateral price drops
    // 5. liquidate both troves
    function test_liquidateTroves(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 2, maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        uint256 _halfAmount = _amount / 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _halfAmount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _halfAmount + troveManager.get_upfront_fee(_halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open a trove for the first borrower
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

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
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), _halfAmount, 1, "E17");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E18");

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

        // Open a trove for the second borrower
        uint256 _anotherTroveId = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        _trove = troveManager.troves(_anotherTroveId);
        assertEq(_trove.debt, _expectedDebt, "E27");
        assertEq(_trove.collateral, _collateralNeeded, "E28");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E29");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E30");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E31");
        assertEq(_trove.owner, anotherUserBorrower, "E32");
        assertEq(_trove.pending_owner, address(0), "E33");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E34");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E35"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E36");
        assertEq(sortedTroves.size(), 2, "E37");
        assertEq(sortedTroves.first(), _troveId, "E38");
        assertEq(sortedTroves.last(), _anotherTroveId, "E39");
        assertTrue(sortedTroves.contains(_troveId), "E40");
        assertTrue(sortedTroves.contains(_anotherTroveId), "E41");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E42");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E43");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E44");
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E45");
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _halfAmount, "E46");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E47");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E48");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E49");
        assertEq(troveManager.zombie_trove_id(), 0, "E50");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E51");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E52");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E53");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E54");

        uint256 _priceBefore = priceOracle.price();

        // Drop collateral price to put trove below MCR
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracle.price.selector),
            abi.encode(_priceBefore / 2) // 50% drop
        );

        // Make sure price actually dropped
        assertEq(priceOracle.price(), _priceBefore / 2, "E55");

        // Calculate Trove's collateral ratio after price drop
        uint256 _troveCollateralRatioAfter = _trove.collateral * priceOracle.price() / _trove.debt;

        // Make sure Trove is below MCR
        assertLt(_troveCollateralRatioAfter, troveManager.MINIMUM_COLLATERAL_RATIO(), "E56");

        // Airdrop borrow tokens to the liquidator
        airdrop(address(borrowToken), liquidator, _expectedDebt * 2);

        // Finally, liquidate the troves
        vm.startPrank(liquidator);
        borrowToken.approve(address(liquidationHandler), _expectedDebt * 2);
        uint256[MAX_LIQUIDATION_BATCH_SIZE] memory _troveIdsToLiquidate;
        _troveIdsToLiquidate[0] = _troveId;
        _troveIdsToLiquidate[1] = _anotherTroveId;
        troveManager.liquidate_troves(_troveIdsToLiquidate);
        vm.stopPrank();

        // Make sure lender got all the borrow tokens back
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), _expectedDebt * 2, 1, "E57");

        // Make sure liquidator got the collateral
        assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded * 2, "E58");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E59");
        assertEq(_trove.collateral, 0, "E60");
        assertEq(_trove.annual_interest_rate, 0, "E61");
        assertEq(_trove.last_debt_update_time, 0, "E62");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E63");
        assertEq(_trove.owner, address(0), "E64");
        assertEq(_trove.pending_owner, address(0), "E65");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E66");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E67");
        assertEq(sortedTroves.size(), 0, "E68");
        assertEq(sortedTroves.first(), 0, "E69");
        assertEq(sortedTroves.last(), 0, "E70");
        assertFalse(sortedTroves.contains(_troveId), "E71");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E72");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E73");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E74");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E75");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E76");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E77");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E78");
        assertEq(troveManager.total_weighted_debt(), 0, "E79");
        assertEq(troveManager.collateral_balance(), 0, "E80");
        assertEq(troveManager.zombie_trove_id(), 0, "E81");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E82");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E83");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E84");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E85");

        // Check everything again for the second trove

        // Check trove info
        _trove = troveManager.troves(_anotherTroveId);
        assertEq(_trove.debt, 0, "E86");
        assertEq(_trove.collateral, 0, "E87");
        assertEq(_trove.annual_interest_rate, 0, "E88");
        assertEq(_trove.last_debt_update_time, 0, "E89");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E90");
        assertEq(_trove.owner, address(0), "E91");
        assertEq(_trove.pending_owner, address(0), "E92");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E93");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E94");
        assertEq(sortedTroves.size(), 0, "E95");
        assertEq(sortedTroves.first(), 0, "E96");
        assertEq(sortedTroves.last(), 0, "E97");
        assertFalse(sortedTroves.contains(_anotherTroveId), "E98");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E99");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E100");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E101");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E102");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E103");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E104");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E105");
        assertEq(troveManager.total_weighted_debt(), 0, "E106");
        assertEq(troveManager.collateral_balance(), 0, "E107");
        assertEq(troveManager.zombie_trove_id(), 0, "E108");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E109");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E110");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E111");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E112");

        // Check liquidation handler is empty
        assertEq(borrowToken.balanceOf(address(liquidationHandler)), 0, "E113");
        assertEq(collateralToken.balanceOf(address(liquidationHandler)), 0, "E114");
    }

    function test_liquidateTroves_emptyList() public {
        // Make sure we always fail when no trove ids are passed
        uint256[MAX_LIQUIDATION_BATCH_SIZE] memory _troveIdsToLiquidate;
        vm.expectRevert("!trove_ids");
        troveManager.liquidate_troves(_troveIdsToLiquidate);
    }

    function test_liquidateTroves_nonExistentTrove(
        uint256 _nonExistentTroveId
    ) public {
        _nonExistentTroveId = bound(_nonExistentTroveId, 1, type(uint256).max);
        // Make sure we always fail when a non-existent trove is passed
        uint256[MAX_LIQUIDATION_BATCH_SIZE] memory _troveIdsToLiquidate;
        _troveIdsToLiquidate[0] = _nonExistentTroveId;
        vm.expectRevert("!active or zombie");
        troveManager.liquidate_troves(_troveIdsToLiquidate);
    }

    function test_liquidateTroves_aboveMCR(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Make sure we cannot liquidate a trove that is above MCR
        uint256[MAX_LIQUIDATION_BATCH_SIZE] memory _troveIdsToLiquidate;
        _troveIdsToLiquidate[0] = _troveId;
        vm.expectRevert(">=MCR");
        troveManager.liquidate_troves(_troveIdsToLiquidate);
    }

}
