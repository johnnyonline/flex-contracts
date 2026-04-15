// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceOracleNotScaled} from "./interfaces/IPriceOracleNotScaled.sol";
import {IPriceOracleScaled} from "./interfaces/IPriceOracleScaled.sol";

import "./Base.sol";

contract LiquidateTests is Base {

    function setUp() public override {
        Base.setUp();

        // Set `profitMaxUnlockTime` to 0
        vm.prank(address(daddy));
        lender.setProfitMaxUnlockTime(0);

        // Set fees to 0
        vm.prank(address(daddy));
        lender.setPerformanceFee(0);
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. collateral price drops
    // 4. liquidate trove
    function test_liquidateTrove(
        uint256 _amount
    ) public {
        // Bound near min_debt to ensure safe CR cap + min_debt check forces full liquidation
        _amount = bound(_amount, troveManager.min_debt(), troveManager.min_debt() * 13 / 10);

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

        // CR = (collateral * price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / debt
        // So price_at_MCR = MCR * debt * ORACLE_PRICE_SCALE / (collateral * BORROW_TOKEN_PRECISION)
        // We want to be 1% below MCR
        uint256 _priceDropToBelowMCR;
        if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
            // For low-decimal borrow tokens (e.g., USDC 6d), multiply first to avoid underflow
            _priceDropToBelowMCR =
                troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
        } else {
            // For high-decimal borrow tokens (e.g., crvUSD 18d), divide first to avoid overflow
            _priceDropToBelowMCR =
                troveManager.minimum_collateral_ratio() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
        }
        uint256 _priceDropToBelowMCR18 = _priceDropToBelowMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);

        // Drop collateral price to put trove below MCR
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceDropToBelowMCR));
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_priceDropToBelowMCR18));

        // Make sure price actually dropped
        assertEq(priceOracle.get_price(), _priceDropToBelowMCR, "E24");

        // Calculate Trove's collateral ratio after price drop
        uint256 _troveCollateralRatioAfter = (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;

        // Make sure Trove is below MCR
        assertLt(_troveCollateralRatioAfter, troveManager.minimum_collateral_ratio(), "E25");

        // Calculate expected collateral to decrease
        uint256 _expectedCollateralToDecrease =
            calculateCollateralToDecrease(_troveCollateralRatioAfter, _expectedDebt, _priceDropToBelowMCR, _collateralNeeded);
        uint256 _expectedRemainingCollateral = _collateralNeeded - _expectedCollateralToDecrease;

        // Finally, liquidate the trove
        liquidate(_troveId);

        // Make sure lender got all the borrow tokens back
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E26");

        // Make sure liquidator mock got the collateral
        assertEq(collateralToken.balanceOf(address(liquidatorMock)), _expectedCollateralToDecrease, "E27");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E28");
        assertEq(_trove.collateral, 0, "E29");
        assertEq(_trove.annual_interest_rate, 0, "E30");
        assertEq(_trove.last_debt_update_time, 0, "E31");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E32");
        assertEq(_trove.owner, address(0), "E33");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E34");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E35");
        assertEq(sortedTroves.size(), 0, "E36");
        assertEq(sortedTroves.first(), 0, "E37");
        assertEq(sortedTroves.last(), 0, "E38");
        assertFalse(sortedTroves.contains(_troveId), "E39");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E40");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E41");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _expectedRemainingCollateral, "E42");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E43");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E44");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E45");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E46");
        assertEq(troveManager.total_weighted_debt(), 0, "E47");
        assertEq(troveManager.collateral_balance(), 0, "E48");
        assertEq(troveManager.zombie_trove_id(), 0, "E49");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E50");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E51");
    }

    // 1. lend
    // 2. borrow half of available liquidity from 1st borrower
    // 3. borrow half of available liquidity from 2nd borrower
    // 4. collateral price drops
    // 5. liquidate both troves
    function test_liquidateTroves(
        uint256 _amount
    ) public {
        // Bound near min_debt to ensure safe CR cap + min_debt check forces full liquidation per trove
        _amount = bound(_amount, troveManager.min_debt() * 2, troveManager.min_debt() * 26 / 10);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        uint256 _halfAmount = _amount / 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_halfAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

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
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), _halfAmount, 1, "E16");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E17");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E18");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E19");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E20");
        assertEq(troveManager.zombie_trove_id(), 0, "E21");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E22");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E23");

        // Open a trove for the second borrower
        uint256 _anotherTroveId = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        _trove = troveManager.troves(_anotherTroveId);
        assertEq(_trove.debt, _expectedDebt, "E24");
        assertEq(_trove.collateral, _collateralNeeded, "E25");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E26");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E27");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E28");
        assertEq(_trove.owner, anotherUserBorrower, "E29");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E30");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E31"
        ); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E32");
        assertEq(sortedTroves.size(), 2, "E33");
        assertEq(sortedTroves.first(), _troveId, "E34");
        assertEq(sortedTroves.last(), _anotherTroveId, "E35");
        assertTrue(sortedTroves.contains(_troveId), "E36");
        assertTrue(sortedTroves.contains(_anotherTroveId), "E37");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E38");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E39");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E40");
        assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E41");
        assertEq(borrowToken.balanceOf(anotherUserBorrower), _halfAmount, "E42");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt * 2, "E43");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E44");
        assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E45");
        assertEq(troveManager.zombie_trove_id(), 0, "E46");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E47");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E48");

        // CR = (collateral * price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / debt
        // So price_at_MCR = MCR * debt * ORACLE_PRICE_SCALE / (collateral * BORROW_TOKEN_PRECISION)
        // We want to be 1% below MCR
        uint256 _priceDropToBelowMCR;
        if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
            // For low-decimal borrow tokens (e.g., USDC 6d), multiply first to avoid underflow
            _priceDropToBelowMCR =
                troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
        } else {
            // For high-decimal borrow tokens (e.g., crvUSD 18d), divide first to avoid overflow
            _priceDropToBelowMCR =
                troveManager.minimum_collateral_ratio() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
        }
        uint256 _priceDropToBelowMCR18 = _priceDropToBelowMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);

        // Drop collateral price to put trove below MCR
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceDropToBelowMCR));
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_priceDropToBelowMCR18));

        // Make sure price actually dropped
        assertEq(priceOracle.get_price(), _priceDropToBelowMCR, "E49");

        // Calculate Trove's collateral ratio after price drop
        uint256 _troveCollateralRatioAfter = (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;

        // Make sure Trove is below MCR
        assertLt(_troveCollateralRatioAfter, troveManager.minimum_collateral_ratio(), "E50");

        // Calculate expected collateral to decrease (same for both troves)
        uint256 _expectedCollateralToDecrease =
            calculateCollateralToDecrease(_troveCollateralRatioAfter, _expectedDebt, _priceDropToBelowMCR, _collateralNeeded);
        uint256 _expectedRemainingCollateral = _collateralNeeded - _expectedCollateralToDecrease;

        // Finally, liquidate both troves
        liquidate(_troveId);
        liquidate(_anotherTroveId);

        // Make sure lender got all the borrow tokens back
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt * 2, "E51");

        // Make sure liquidator mock got the collateral
        assertEq(collateralToken.balanceOf(address(liquidatorMock)), _expectedCollateralToDecrease * 2, "E52");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E53");
        assertEq(_trove.collateral, 0, "E54");
        assertEq(_trove.annual_interest_rate, 0, "E55");
        assertEq(_trove.last_debt_update_time, 0, "E56");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E57");
        assertEq(_trove.owner, address(0), "E58");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E59");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E60");
        assertEq(sortedTroves.size(), 0, "E61");
        assertEq(sortedTroves.first(), 0, "E62");
        assertEq(sortedTroves.last(), 0, "E63");
        assertFalse(sortedTroves.contains(_troveId), "E64");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E65");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E66");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _expectedRemainingCollateral, "E67");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E68");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E69");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E70");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E71");
        assertEq(troveManager.total_weighted_debt(), 0, "E72");
        assertEq(troveManager.collateral_balance(), 0, "E73");
        assertEq(troveManager.zombie_trove_id(), 0, "E74");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E75");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E76");

        // Check everything again for the second trove

        // Check trove info
        _trove = troveManager.troves(_anotherTroveId);
        assertEq(_trove.debt, 0, "E77");
        assertEq(_trove.collateral, 0, "E78");
        assertEq(_trove.annual_interest_rate, 0, "E79");
        assertEq(_trove.last_debt_update_time, 0, "E80");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E81");
        assertEq(_trove.owner, address(0), "E82");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E83");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E84");
        assertEq(sortedTroves.size(), 0, "E85");
        assertEq(sortedTroves.first(), 0, "E86");
        assertEq(sortedTroves.last(), 0, "E87");
        assertFalse(sortedTroves.contains(_anotherTroveId), "E88");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E89");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E90");
        assertEq(collateralToken.balanceOf(address(userBorrower)), _expectedRemainingCollateral, "E91");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E92");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E93");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E94");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E95");
        assertEq(troveManager.total_weighted_debt(), 0, "E96");
        assertEq(troveManager.collateral_balance(), 0, "E97");
        assertEq(troveManager.zombie_trove_id(), 0, "E98");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E99");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E100");
    }

    // 1. lend
    // 2. open 2 troves
    // 3. collateral price drops
    // 4. liquidate first trove
    // 5. liquidate second trove
    function test_liquidateTroves_sequentialLiquidations(
        uint256 _amount
    ) public {
        // Bound near min_debt to ensure safe CR cap + min_debt check forces full liquidation per trove
        _amount = bound(_amount, troveManager.min_debt() * 2, troveManager.min_debt() * 26 / 10);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        uint256 _halfAmount = _amount / 2;

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_halfAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _expectedDebt = _halfAmount + troveManager.get_upfront_fee(_halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open first trove
        uint256 _troveId1 = mintAndOpenTrove(userBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Open second trove
        uint256 _troveId2 = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info for first trove
        ITroveManager.Trove memory _trove1 = troveManager.troves(_troveId1);
        assertEq(_trove1.debt, _expectedDebt, "E0");
        assertEq(_trove1.collateral, _collateralNeeded, "E1");

        // Check trove info for second trove
        ITroveManager.Trove memory _trove2 = troveManager.troves(_troveId2);
        assertEq(_trove2.debt, _expectedDebt, "E2");
        assertEq(_trove2.collateral, _collateralNeeded, "E3");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E4");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E5");

        // CR = collateral * price / debt, so price_at_MCR = MCR * debt / collateral
        // We want to be 1% below MCR
        uint256 _priceDropToBelowMCR;
        if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
            // For low-decimal borrow tokens (e.g., USDC 6d), multiply first to avoid underflow
            _priceDropToBelowMCR = troveManager.minimum_collateral_ratio() * _trove1.debt * ORACLE_PRICE_SCALE * 99
                / (100 * _trove1.collateral * BORROW_TOKEN_PRECISION);
        } else {
            // For high-decimal borrow tokens (e.g., crvUSD 18d), divide first to avoid overflow
            _priceDropToBelowMCR =
                troveManager.minimum_collateral_ratio() * _trove1.debt * 99 / 100 / _trove1.collateral * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION;
        }
        uint256 _priceDropToBelowMCR18 = _priceDropToBelowMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);

        // Drop collateral price to put both troves below MCR
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceDropToBelowMCR));
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_priceDropToBelowMCR18));

        // Make sure price actually dropped
        assertEq(priceOracle.get_price(), _priceDropToBelowMCR, "E6");

        // Make sure both troves are below MCR
        assertLt(
            (_trove1.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove1.debt,
            troveManager.minimum_collateral_ratio(),
            "E7"
        );
        assertLt(
            (_trove2.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove2.debt,
            troveManager.minimum_collateral_ratio(),
            "E8"
        );

        // Calculate expected collateral to decrease (same for both troves)
        uint256 _troveCollateralRatioAfter =
            (_trove1.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove1.debt;
        uint256 _expectedCollateralToDecrease =
            calculateCollateralToDecrease(_troveCollateralRatioAfter, _expectedDebt, _priceDropToBelowMCR, _collateralNeeded);

        // Liquidate the first trove
        liquidate(_troveId1);

        // Check liquidator mock received collateral from first trove
        assertEq(collateralToken.balanceOf(address(liquidatorMock)), _expectedCollateralToDecrease, "E9");

        // Check first trove is liquidated
        assertEq(uint256(troveManager.troves(_troveId1).status), uint256(ITroveManager.Status.liquidated), "E10");

        // Check second trove is still active
        assertEq(uint256(troveManager.troves(_troveId2).status), uint256(ITroveManager.Status.active), "E11");

        // Liquidate the second trove
        liquidate(_troveId2);

        // Check second trove is now liquidated
        assertEq(uint256(troveManager.troves(_troveId2).status), uint256(ITroveManager.Status.liquidated), "E12");

        // Make sure lender got all the borrow tokens back
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt * 2, "E13");

        // Make sure liquidator mock got all the collateral
        assertEq(collateralToken.balanceOf(address(liquidatorMock)), _expectedCollateralToDecrease * 2, "E14");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E15");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E16");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E17");
        assertEq(troveManager.total_weighted_debt(), 0, "E18");
        assertEq(troveManager.collateral_balance(), 0, "E19");
    }

    // Liquidate 4 troves at different price levels to test fee scaling:
    // 1. Near MCR --> min fee (0.5%)
    // 2. Midpoint between MCR and max penalty CR --> interpolated fee (~max/2)
    // 3. At max penalty CR --> max fee (5%)
    // 4. Price back up near MCR --> min fee (0.5%) again
    function test_liquidateTrove_feeScaling() public {
        uint256 _minDebt = troveManager.min_debt();
        uint256 _collateralNeeded =
            (_minDebt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        mintAndDepositIntoLender(userLender, _minDebt * 4);

        uint256 _troveId1 = mintAndOpenTrove(address(1001), _collateralNeeded, _minDebt, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _troveId2 = mintAndOpenTrove(address(1002), _collateralNeeded, _minDebt, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _troveId3 = mintAndOpenTrove(address(1003), _collateralNeeded, _minDebt, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _troveId4 = mintAndOpenTrove(address(1004), _collateralNeeded, _minDebt, DEFAULT_ANNUAL_INTEREST_RATE);

        ITroveManager.Trove memory _trove = troveManager.troves(_troveId1);
        uint256 _mcr = troveManager.minimum_collateral_ratio();
        uint256 _maxPenaltyCR = troveManager.max_penalty_collateral_ratio();

        // Price levels for different fee tiers
        uint256 _priceNearMCR = (_mcr - 1) * _trove.debt * ORACLE_PRICE_SCALE / (_trove.collateral * BORROW_TOKEN_PRECISION);
        uint256 _priceMid = ((_mcr + _maxPenaltyCR) / 2) * _trove.debt * ORACLE_PRICE_SCALE / (_trove.collateral * BORROW_TOKEN_PRECISION);
        uint256 _priceMaxPenalty = _maxPenaltyCR * _trove.debt * ORACLE_PRICE_SCALE / (_trove.collateral * BORROW_TOKEN_PRECISION);

        uint256 _balBefore;
        uint256 _baseCollateral;

        // --- Trove 1: CR just below MCR --> min fee (0.5%) ---
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceNearMCR));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_priceNearMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );
        _balBefore = collateralToken.balanceOf(address(liquidatorMock));
        liquidate(_troveId1);
        uint256 _received1 = collateralToken.balanceOf(address(liquidatorMock)) - _balBefore;
        _baseCollateral = _trove.debt * ORACLE_PRICE_SCALE / _priceNearMCR;
        assertApproxEqRel(
            _received1, _baseCollateral * (BORROW_TOKEN_PRECISION + troveManager.min_liquidation_fee()) / BORROW_TOKEN_PRECISION, 1e15, "E0"
        );

        // --- Trove 2: CR at midpoint --> interpolated fee (~max/2) ---
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceMid));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_priceMid * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );
        _balBefore = collateralToken.balanceOf(address(liquidatorMock));
        liquidate(_troveId2);
        uint256 _received2 = collateralToken.balanceOf(address(liquidatorMock)) - _balBefore;
        _baseCollateral = _trove.debt * ORACLE_PRICE_SCALE / _priceMid;
        assertApproxEqRel(
            _received2, _baseCollateral * (BORROW_TOKEN_PRECISION + troveManager.max_liquidation_fee() / 2) / BORROW_TOKEN_PRECISION, 1e16, "E1"
        );

        // --- Trove 3: CR at max penalty --> max fee (5%) ---
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceMaxPenalty));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_priceMaxPenalty * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );
        _balBefore = collateralToken.balanceOf(address(liquidatorMock));
        liquidate(_troveId3);
        uint256 _received3 = collateralToken.balanceOf(address(liquidatorMock)) - _balBefore;
        _baseCollateral = _trove.debt * ORACLE_PRICE_SCALE / _priceMaxPenalty;
        assertEq(_received3, _baseCollateral * (BORROW_TOKEN_PRECISION + troveManager.max_liquidation_fee()) / BORROW_TOKEN_PRECISION, "E2");

        // --- Trove 4: price back up near MCR --> min fee (0.5%) again ---
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceNearMCR));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_priceNearMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );
        _balBefore = collateralToken.balanceOf(address(liquidatorMock));
        liquidate(_troveId4);
        uint256 _received4 = collateralToken.balanceOf(address(liquidatorMock)) - _balBefore;

        // Verify fee scaling: more collateral at lower CRs
        assertLt(_received1, _received2, "E3");
        assertLt(_received2, _received3, "E4");
        assertEq(_received1, _received4, "E5");
    }

    // Partial liquidation: liquidate 1/4 of the debt, trove stays open with improved CR
    function test_liquidateTrove_partial(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);

        // Drop price to 1% below MCR
        uint256 _price;
        if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
        } else {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
        }
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_price));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_price * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );

        uint256 _crBefore = (_trove.collateral * _price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;
        assertLt(_crBefore, troveManager.minimum_collateral_ratio(), "E0");

        // Partial liquidation: liquidate 1/4 of the debt
        uint256 _debtToLiquidate = _trove.debt / 4;
        uint256 _expectedCollateral = calculateCollateralToDecrease(_crBefore, _debtToLiquidate, _price, _trove.collateral);

        liquidatorMock.liquidate(_troveId, _debtToLiquidate);

        // Trove should still be active with reduced debt and collateral
        ITroveManager.Trove memory _troveAfter = troveManager.troves(_troveId);
        assertEq(uint256(_troveAfter.status), uint256(ITroveManager.Status.active), "E1");
        assertEq(_troveAfter.debt, _trove.debt - _debtToLiquidate, "E2");
        assertEq(_troveAfter.collateral, _trove.collateral - _expectedCollateral, "E3");
        assertEq(_troveAfter.owner, userBorrower, "E4");

        // CR should have improved and be above MCR
        uint256 _crAfter = (_troveAfter.collateral * _price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _troveAfter.debt;
        assertGt(_crAfter, _crBefore, "E5");
        assertGe(_crAfter, troveManager.minimum_collateral_ratio(), "E6");

        // Liquidator received correct collateral
        assertEq(collateralToken.balanceOf(address(liquidatorMock)), _expectedCollateral, "E7");

        // Trove owner did not receive collateral (only happens on full liquidation)
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E8");

        // Trove still in sorted list
        assertTrue(sortedTroves.contains(_troveId), "E9");
    }

    // Partial liquidation that triggers full: remaining debt would be below min_debt
    function test_liquidateTrove_partialBecomesFullBelowMinDebt(
        uint256 _amount
    ) public {
        // Bound near min_debt to ensure safe CR cap doesn't override the explicit partial amount
        _amount = bound(_amount, troveManager.min_debt(), troveManager.min_debt() * 13 / 10);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);

        // Drop price to 1% below MCR
        uint256 _price;
        if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
        } else {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
        }
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_price));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_price * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );

        // Try partial: amount that would leave remaining below min_debt --> forced full
        uint256 _partialDebt = _trove.debt - troveManager.min_debt() + 1;

        // Expected collateral for full liquidation (full debt, not partial)
        uint256 _cr = (_trove.collateral * _price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;
        uint256 _expectedCollateral = calculateCollateralToDecrease(_cr, _trove.debt, _price, _trove.collateral);
        uint256 _expectedRemaining = _trove.collateral - _expectedCollateral;

        liquidatorMock.liquidate(_troveId, _partialDebt);

        // Trove should be fully liquidated (not partial)
        ITroveManager.Trove memory _troveAfter = troveManager.troves(_troveId);
        assertEq(uint256(_troveAfter.status), uint256(ITroveManager.Status.liquidated), "E0");
        assertEq(_troveAfter.debt, 0, "E1");
        assertEq(_troveAfter.collateral, 0, "E2");

        // Liquidator got the collateral_to_decrease (for full debt, not the partial amount)
        assertEq(collateralToken.balanceOf(address(liquidatorMock)), _expectedCollateral, "E3");

        // Trove owner got the remaining collateral
        assertEq(collateralToken.balanceOf(userBorrower), _expectedRemaining, "E4");

        // Trove removed from sorted list
        assertFalse(sortedTroves.contains(_troveId), "E5");
    }

    function test_liquidateTrove_nonExistentTrove(
        uint256 _nonExistentTroveId
    ) public {
        _nonExistentTroveId = bound(_nonExistentTroveId, 1, type(uint256).max);
        // Make sure we always fail when a non-existent trove is passed
        vm.expectRevert("!active or zombie");
        liquidatorMock.liquidate(_nonExistentTroveId, type(uint256).max);
    }

    function test_liquidateTrove_zeroTroveId() public {
        vm.expectRevert("!active or zombie");
        liquidatorMock.liquidate(0, type(uint256).max);
    }

    function test_liquidateTrove_aboveMCR(
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

        // Make sure we cannot liquidate a trove that is above MCR
        vm.expectRevert("!collateral_ratio");
        liquidatorMock.liquidate(_troveId, type(uint256).max);
    }

    function test_liquidateGas() public {
        uint256 _amount = troveManager.min_debt() * BORROW_TOKEN_PRECISION;

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Drop price below MCR
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        uint256 _priceDropToBelowMCR =
            troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
        uint256 _priceDropToBelowMCR18 = _priceDropToBelowMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);

        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceDropToBelowMCR));
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_priceDropToBelowMCR18));

        uint256 _gasBefore = gasleft();
        liquidate(_troveId);
        uint256 _gasUsed = _gasBefore - gasleft();

        console2.log("Gas used to liquidate 1 trove:", _gasUsed);
    }

    // Passing max_debt_to_repay = type(uint256).max should cap the liquidation at safe CR
    // --> trove stays open with CR ≈ safe_collateral_ratio
    function test_liquidateTrove_capsAtSafeCR(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 4, maxFuzzAmount);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);

        // Drop price to 1% below MCR
        uint256 _price;
        if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
        } else {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
        }
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_price));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_price * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );

        uint256 _crBefore = (_trove.collateral * _price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;
        assertLt(_crBefore, troveManager.minimum_collateral_ratio(), "E0");

        // Liquidate with max_debt = type(uint256).max --> should be capped at safe CR
        liquidate(_troveId);

        // Trove should still be active (partial liquidation, not full)
        ITroveManager.Trove memory _troveAfter = troveManager.troves(_troveId);
        assertEq(uint256(_troveAfter.status), uint256(ITroveManager.Status.active), "E1");
        assertGt(_troveAfter.debt, 0, "E2");
        assertGt(_troveAfter.collateral, 0, "E3");

        // CR should have improved
        uint256 _crAfter = (_troveAfter.collateral * _price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _troveAfter.debt;
        assertGt(_crAfter, _crBefore, "E4");

        // CR should be approximately equal to safe_collateral_ratio
        assertApproxEqRel(_crAfter, troveManager.safe_collateral_ratio(), 1e16, "E5"); // 1% tolerance

        // CR should be above MCR
        assertGe(_crAfter, troveManager.minimum_collateral_ratio(), "E6");

        // Trove still in sorted list
        assertTrue(sortedTroves.contains(_troveId), "E7");

        // Trove owner did not receive collateral (partial liquidation)
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E8");
    }

    // When max_debt_to_repay < safe CR cap, the smaller value is used
    function test_liquidateTrove_maxDebtRespectedBelowSafeCRCap(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 4, maxFuzzAmount);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);

        // Drop price to 1% below MCR
        uint256 _price;
        if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
        } else {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
        }
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_price));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_price * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );

        // Liquidate a small amount (1/4 of debt) -- less than what safe CR would allow
        uint256 _smallDebt = _trove.debt / 4;
        uint256 _crBefore = (_trove.collateral * _price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;
        uint256 _expectedCollateral = calculateCollateralToDecrease(_crBefore, _smallDebt, _price, _trove.collateral);

        liquidatorMock.liquidate(_troveId, _smallDebt);

        // Trove should be active with exactly the requested debt removed
        ITroveManager.Trove memory _troveAfter = troveManager.troves(_troveId);
        assertEq(uint256(_troveAfter.status), uint256(ITroveManager.Status.active), "E0");
        assertEq(_troveAfter.debt, _trove.debt - _smallDebt, "E1");
        assertEq(_troveAfter.collateral, _trove.collateral - _expectedCollateral, "E2");

        // CR should have improved
        uint256 _crAfter = (_troveAfter.collateral * _price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _troveAfter.debt;
        assertGt(_crAfter, _crBefore, "E3");

        // CR should be below safe CR (we didn't liquidate enough to reach it)
        assertLt(_crAfter, troveManager.safe_collateral_ratio(), "E4");

        // But still above MCR
        assertGe(_crAfter, troveManager.minimum_collateral_ratio(), "E5");
    }

    // When safe CR cap + min_debt check forces full liquidation
    function test_liquidateTrove_safeCRCapForcesFullViaMinDebt(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), troveManager.min_debt() * 13 / 10);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);

        // Drop price to 1% below MCR
        uint256 _price;
        if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
        } else {
            _price =
                troveManager.minimum_collateral_ratio() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
        }
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_price));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_price * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );

        // Liquidate with max --> safe CR cap would leave remaining debt below min_debt --> forced full
        liquidate(_troveId);

        // Trove should be fully liquidated
        ITroveManager.Trove memory _troveAfter = troveManager.troves(_troveId);
        assertEq(uint256(_troveAfter.status), uint256(ITroveManager.Status.liquidated), "E0");
        assertEq(_troveAfter.debt, 0, "E1");
        assertEq(_troveAfter.collateral, 0, "E2");

        // Trove owner received remaining collateral
        assertGt(collateralToken.balanceOf(userBorrower), 0, "E3");

        // Trove removed from sorted list
        assertFalse(sortedTroves.contains(_troveId), "E4");
    }

    // Bad debt scenario: CR < 100% + fee --> safe CR formula returns > total debt --> full liquidation
    function test_liquidateTrove_badDebtFullLiquidation(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);

        // Drop price dramatically to put CR below 100% (bad debt)
        // Target CR ≈ 98%
        uint256 _price = 98 * troveManager.one_pct() * _trove.debt * ORACLE_PRICE_SCALE / (_trove.collateral * BORROW_TOKEN_PRECISION);
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_price));
        vm.mockCall(
            address(priceOracle),
            abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false),
            abi.encode(_price * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION))
        );

        // Verify CR is below 100%
        uint256 _cr = (_trove.collateral * _price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;
        assertLt(_cr, BORROW_TOKEN_PRECISION, "E0");

        // Cache state before liquidation
        uint256 _troveDebtAfterInterest = troveManager.get_trove_debt_after_interest(_troveId);
        uint256 _lenderBalanceBefore = borrowToken.balanceOf(address(lender));

        // Compute expected debt_to_repay: collateral value / (1 + max_fee)
        uint256 _collateralInBorrow = _trove.collateral * _price / ORACLE_PRICE_SCALE;
        uint256 _expectedDebtToRepay = _collateralInBorrow * BORROW_TOKEN_PRECISION / (BORROW_TOKEN_PRECISION + troveManager.max_liquidation_fee());

        // Liquidate — underwater trove is force-fully-liquidated with bad debt socialized
        liquidate(_troveId);

        // Trove should be fully liquidated
        ITroveManager.Trove memory _troveAfter = troveManager.troves(_troveId);
        assertEq(uint256(_troveAfter.status), uint256(ITroveManager.Status.liquidated), "E1");
        assertEq(_troveAfter.debt, 0, "E2");
        assertEq(_troveAfter.collateral, 0, "E3");

        // Liquidator gets all collateral (bad debt means collateral_with_fee > trove.collateral)
        assertEq(collateralToken.balanceOf(address(liquidatorMock)), _trove.collateral, "E4");

        // Trove owner gets nothing (all collateral went to liquidator)
        assertEq(collateralToken.balanceOf(userBorrower), 0, "E5");

        // Trove removed from sorted list
        assertFalse(sortedTroves.contains(_troveId), "E6");

        // Liquidator paid less than the full debt (only collateral value minus max fee)
        uint256 _actualRepaid = borrowToken.balanceOf(address(lender)) - _lenderBalanceBefore;
        assertEq(_actualRepaid, _expectedDebtToRepay, "E7");
        assertLt(_actualRepaid, _troveDebtAfterInterest, "E8");

        // Full debt was cleared from total_debt (bad debt socialized — only one trove, so total_debt is 0)
        assertEq(troveManager.total_debt(), 0, "E9");
    }

    // Redeem all collateral from an underwater trove (CR ≈ 90%), then liquidate the 0-collateral zombie
    // Example: 90 collateral value, 100 debt → redeem 90 debt → 0 collateral, 10 debt → liquidate → debt socialized
    function test_liquidateTrove_zeroCollateralAfterRedemption() public {
        uint256 _amount = troveManager.min_debt();

        // Lend
        mintAndDepositIntoLender(userLender, _amount);

        // Open trove
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);

        // Drop price so trove is deeply underwater (CR ≈ 90%)
        uint256 _price = 90 * troveManager.one_pct() * _trove.debt * ORACLE_PRICE_SCALE / (_trove.collateral * BORROW_TOKEN_PRECISION);
        uint256 _price18 = _price * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_price));
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_price18));

        // Calculate the collateral value in borrow tokens (this is how much debt we can redeem)
        uint256 _collateralValue = _trove.collateral * _price / ORACLE_PRICE_SCALE;

        // Redeem exactly the collateral value worth of debt
        vm.prank(address(lender));
        troveManager.redeem(_collateralValue, address(lender));

        // Trove should be a zombie with ~0 collateral and remaining debt
        ITroveManager.Trove memory _troveAfterRedeem = troveManager.troves(_troveId);
        assertEq(uint256(_troveAfterRedeem.status), uint256(ITroveManager.Status.zombie), "E0");
        assertApproxEqAbs(_troveAfterRedeem.collateral, 0, COLLATERAL_TOKEN_PRECISION, "E1");
        assertGt(_troveAfterRedeem.debt, 0, "E2");

        // Liquidate the zombie trove directly (no callback)
        troveManager.liquidate_trove(_troveId, type(uint256).max, liquidator, "");

        // Trove should be fully liquidated
        ITroveManager.Trove memory _troveAfterLiq = troveManager.troves(_troveId);
        assertEq(uint256(_troveAfterLiq.status), uint256(ITroveManager.Status.liquidated), "E3");
        assertEq(_troveAfterLiq.debt, 0, "E4");
        assertEq(_troveAfterLiq.collateral, 0, "E5");
    }

}
