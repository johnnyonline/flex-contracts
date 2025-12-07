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

        // Check redemption handler is empty
        assertEq(borrowToken.balanceOf(address(redemptionHandler)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(redemptionHandler)), 0, "E24");

        uint256 _priceBefore = priceOracle.price();

        // Drop collateral price to put trove below MCR
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracle.price.selector),
            abi.encode(_priceBefore / 2) // 50% drop
        );

        // Make sure price actually dropped
        assertEq(priceOracle.price(), _priceBefore / 2, "E25");

        // Calculate Trove's collateral ratio after price drop
        uint256 _troveCollateralRatioAfter = _trove.collateral * priceOracle.price() / _trove.debt;

        // Make sure Trove is below MCR
        assertLt(_troveCollateralRatioAfter, troveManager.MINIMUM_COLLATERAL_RATIO(), "E26");

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
        assertEq(borrowToken.balanceOf(address(lender)), _expectedDebt, "E27");

        // Make sure liquidator got the collateral
        assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded, "E28");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E29");
        assertEq(_trove.collateral, 0, "E30");
        assertEq(_trove.annual_interest_rate, 0, "E31");
        assertEq(_trove.last_debt_update_time, 0, "E32");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E33");
        assertEq(_trove.owner, address(0), "E34");
        assertEq(_trove.pending_owner, address(0), "E35");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E36");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E37");
        assertEq(sortedTroves.size(), 0, "E38");
        assertEq(sortedTroves.first(), 0, "E39");
        assertEq(sortedTroves.last(), 0, "E40");
        assertFalse(sortedTroves.contains(_troveId), "E41");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E42");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E43");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E44");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E45");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E46");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E47");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E48");
        assertEq(troveManager.total_weighted_debt(), 0, "E49");
        assertEq(troveManager.collateral_balance(), 0, "E50");
        assertEq(troveManager.zombie_trove_id(), 0, "E51");

        // Check redemption handler is empty
        assertEq(borrowToken.balanceOf(address(redemptionHandler)), 0, "E52");
        assertEq(collateralToken.balanceOf(address(redemptionHandler)), 0, "E53");

        // Check liquidation handler is empty
        assertEq(borrowToken.balanceOf(address(liquidationHandler)), 0, "E54");
        assertEq(collateralToken.balanceOf(address(liquidationHandler)), 0, "E55");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. collateral price drops
    // 4. liquidate trove using dutch auction
    function test_liquidateTrove_dutch(
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

        // Check redemption handler is empty
        assertEq(borrowToken.balanceOf(address(redemptionHandler)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(redemptionHandler)), 0, "E24");

        uint256 _priceBefore = priceOracle.price();

        // Drop collateral price to put trove below MCR
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracle.price.selector),
            abi.encode(_priceBefore * 85 / 100) // 15% drop
        );

        // Make sure price actually dropped
        assertEq(priceOracle.price(), _priceBefore * 85 / 100, "E25");

        // Calculate Trove's collateral ratio after price drop
        uint256 _troveCollateralRatioAfter = _trove.collateral * priceOracle.price() / _trove.debt;

        // Make sure Trove is below MCR
        assertLt(_troveCollateralRatioAfter, troveManager.MINIMUM_COLLATERAL_RATIO(), "E26");

        // Toggle to use auction
        vm.startPrank(management);
        liquidationHandler.accept_ownership();
        liquidationHandler.toggle_use_auction();
        vm.stopPrank();

        // Finally, liquidate the trove
        uint256[MAX_LIQUIDATION_BATCH_SIZE] memory _troveIdsToLiquidate;
        _troveIdsToLiquidate[0] = _troveId;
        troveManager.liquidate_troves(_troveIdsToLiquidate);

        IAuction _auction = IAuction(liquidationHandler.AUCTION());

        // Airdrop borrow tokens to taker
        uint256 _amountNeeded = _auction.getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);

        // Take it
        vm.startPrank(liquidator);
        borrowToken.approve(address(_auction), _amountNeeded);
        _auction.take(address(collateralToken));
        vm.stopPrank();

        // Make sure lender got all the borrow tokens back
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E27");

        // Make sure liquidator got the collateral
        assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded, "E28");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E29");
        assertEq(_trove.collateral, 0, "E30");
        assertEq(_trove.annual_interest_rate, 0, "E31");
        assertEq(_trove.last_debt_update_time, 0, "E32");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E33");
        assertEq(_trove.owner, address(0), "E34");
        assertEq(_trove.pending_owner, address(0), "E35");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E36");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E37");
        assertEq(sortedTroves.size(), 0, "E38");
        assertEq(sortedTroves.first(), 0, "E39");
        assertEq(sortedTroves.last(), 0, "E40");
        assertFalse(sortedTroves.contains(_troveId), "E41");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E42");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E43");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E44");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E45");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E46");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E47");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E48");
        assertEq(troveManager.total_weighted_debt(), 0, "E49");
        assertEq(troveManager.collateral_balance(), 0, "E50");
        assertEq(troveManager.zombie_trove_id(), 0, "E51");

        // Check redemption handler is empty
        assertEq(borrowToken.balanceOf(address(redemptionHandler)), 0, "E52");
        assertEq(collateralToken.balanceOf(address(redemptionHandler)), 0, "E53");

        // Check liquidation handler is empty
        assertEq(borrowToken.balanceOf(address(liquidationHandler)), 0, "E54");
        assertEq(collateralToken.balanceOf(address(liquidationHandler)), 0, "E55");
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

        // Check redemption handler is empty
        assertEq(borrowToken.balanceOf(address(redemptionHandler)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(redemptionHandler)), 0, "E24");

        // Open a trove for the second borrower
        uint256 _anotherTroveId = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        _trove = troveManager.troves(_anotherTroveId);
        assertEq(_trove.debt, _expectedDebt, "E25");
        assertEq(_trove.collateral, _collateralNeeded, "E26");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E27");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E28");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E29");
        assertEq(_trove.owner, anotherUserBorrower, "E30");
        assertEq(_trove.pending_owner, address(0), "E31");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E32");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E33"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E34");
        assertEq(sortedTroves.size(), 2, "E35");
        assertEq(sortedTroves.first(), _troveId, "E36");
        assertEq(sortedTroves.last(), _anotherTroveId, "E37");
        assertTrue(sortedTroves.contains(_troveId), "E38");
        assertTrue(sortedTroves.contains(_anotherTroveId), "E39");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E40");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E41");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E42");
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E43");
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _halfAmount, "E44");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E45");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E46");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E47");
        assertEq(troveManager.zombie_trove_id(), 0, "E48");

        // Check redemption handler is empty
        assertEq(borrowToken.balanceOf(address(redemptionHandler)), 0, "E49");
        assertEq(collateralToken.balanceOf(address(redemptionHandler)), 0, "E50");

        uint256 _priceBefore = priceOracle.price();

        // Drop collateral price to put trove below MCR
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracle.price.selector),
            abi.encode(_priceBefore / 2) // 50% drop
        );

        // Make sure price actually dropped
        assertEq(priceOracle.price(), _priceBefore / 2, "E51");

        // Calculate Trove's collateral ratio after price drop
        uint256 _troveCollateralRatioAfter = _trove.collateral * priceOracle.price() / _trove.debt;

        // Make sure Trove is below MCR
        assertLt(_troveCollateralRatioAfter, troveManager.MINIMUM_COLLATERAL_RATIO(), "E52");

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
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), _expectedDebt * 2, 1, "E53");

        // Make sure liquidator got the collateral
        assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded * 2, "E54");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E55");
        assertEq(_trove.collateral, 0, "E56");
        assertEq(_trove.annual_interest_rate, 0, "E57");
        assertEq(_trove.last_debt_update_time, 0, "E58");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E59");
        assertEq(_trove.owner, address(0), "E60");
        assertEq(_trove.pending_owner, address(0), "E61");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E62");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E63");
        assertEq(sortedTroves.size(), 0, "E64");
        assertEq(sortedTroves.first(), 0, "E65");
        assertEq(sortedTroves.last(), 0, "E66");
        assertFalse(sortedTroves.contains(_troveId), "E67");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E68");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E69");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E70");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E71");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E72");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E73");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E74");
        assertEq(troveManager.total_weighted_debt(), 0, "E75");
        assertEq(troveManager.collateral_balance(), 0, "E76");
        assertEq(troveManager.zombie_trove_id(), 0, "E77");

        // Check redemption handler is empty
        assertEq(borrowToken.balanceOf(address(redemptionHandler)), 0, "E78");
        assertEq(collateralToken.balanceOf(address(redemptionHandler)), 0, "E79");

        // Check everything again for the second trove

        // Check trove info
        _trove = troveManager.troves(_anotherTroveId);
        assertEq(_trove.debt, 0, "E80");
        assertEq(_trove.collateral, 0, "E81");
        assertEq(_trove.annual_interest_rate, 0, "E82");
        assertEq(_trove.last_debt_update_time, 0, "E83");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E84");
        assertEq(_trove.owner, address(0), "E85");
        assertEq(_trove.pending_owner, address(0), "E86");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E87");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E88");
        assertEq(sortedTroves.size(), 0, "E89");
        assertEq(sortedTroves.first(), 0, "E90");
        assertEq(sortedTroves.last(), 0, "E91");
        assertFalse(sortedTroves.contains(_anotherTroveId), "E92");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E93");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E94");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E95");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E96");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E97");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E98");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E99");
        assertEq(troveManager.total_weighted_debt(), 0, "E100");
        assertEq(troveManager.collateral_balance(), 0, "E101");
        assertEq(troveManager.zombie_trove_id(), 0, "E102");

        // Check redemption handler is empty
        assertEq(borrowToken.balanceOf(address(redemptionHandler)), 0, "E103");
        assertEq(collateralToken.balanceOf(address(redemptionHandler)), 0, "E104");

        // Check liquidation handler is empty
        assertEq(borrowToken.balanceOf(address(liquidationHandler)), 0, "E105");
        assertEq(collateralToken.balanceOf(address(liquidationHandler)), 0, "E106");
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
