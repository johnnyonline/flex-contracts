// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.23;

// import "./Base.sol";
// import {IPriceOracleNotScaled} from "./interfaces/IPriceOracleNotScaled.sol";
// import {IPriceOracleScaled} from "./interfaces/IPriceOracleScaled.sol";

// contract LiquidateTests is Base {

//     function setUp() public override {
//         Base.setUp();

//         // Set `profitMaxUnlockTime` to 0
//         vm.prank(management);
//         lender.setProfitMaxUnlockTime(0);

//         // Set fees to 0
//         vm.prank(management);
//         lender.setPerformanceFee(0);
//     }

//     // 1. lend
//     // 2. borrow all available liquidity
//     // 3. collateral price drops
//     // 4. liquidate trove
//     function test_liquidateTrove(
//         uint256 _amount
//     ) public {
//         _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

//         // Lend some from lender
//         mintAndDepositIntoLender(userLender, _amount);

//         // Calculate how much collateral is needed for the borrow amount
//         uint256 _collateralNeeded =
//             (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

//         // Calculate expected debt (borrow amount + upfront fee)
//         uint256 _expectedDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Open a trove
//         uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Check trove info
//         ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
//         assertEq(_trove.debt, _expectedDebt, "E0");
//         assertEq(_trove.collateral, _collateralNeeded, "E1");
//         assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
//         assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
//         assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
//         assertEq(_trove.owner, userBorrower, "E5");
//         assertEq(_trove.pending_owner, address(0), "E6");
//         assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
//         assertApproxEqRel(
//             (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
//             DEFAULT_TARGET_COLLATERAL_RATIO,
//             1e15,
//             "E8"
//         ); // 0.1%

//         // Check sorted troves
//         assertFalse(sortedTroves.empty(), "E9");
//         assertEq(sortedTroves.size(), 1, "E10");
//         assertEq(sortedTroves.first(), _troveId, "E11");
//         assertEq(sortedTroves.last(), _troveId, "E12");
//         assertTrue(sortedTroves.contains(_troveId), "E13");

//         // Check balances
//         assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E14");
//         assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E15");
//         assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E16");
//         assertEq(borrowToken.balanceOf(address(lender)), 0, "E17");
//         assertEq(borrowToken.balanceOf(userBorrower), _amount, "E18");

//         // Check global info
//         assertEq(troveManager.total_debt(), _expectedDebt, "E19");
//         assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
//         assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
//         assertEq(troveManager.zombie_trove_id(), 0, "E22");

//         // Check dutch desk is empty
//         assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
//         assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

//         // CR = (collateral * price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / debt
//         // So price_at_MCR = MCR * debt * ORACLE_PRICE_SCALE / (collateral * BORROW_TOKEN_PRECISION)
//         // We want to be 1% below MCR
//         uint256 _priceDropToBelowMCR;
//         if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
//             // For low-decimal borrow tokens (e.g., USDC 6d), multiply first to avoid underflow
//             _priceDropToBelowMCR =
//                 troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
//         } else {
//             // For high-decimal borrow tokens (e.g., crvUSD 18d), divide first to avoid overflow
//             _priceDropToBelowMCR =
//                 troveManager.minimum_collateral_ratio() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
//         }
//         uint256 _priceDropToBelowMCR18 = _priceDropToBelowMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);

//         // Drop collateral price to put trove below MCR
//         vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceDropToBelowMCR));
//         vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_priceDropToBelowMCR18));

//         // Make sure price actually dropped
//         assertEq(priceOracle.get_price(), _priceDropToBelowMCR, "E25");

//         // Calculate Trove's collateral ratio after price drop
//         uint256 _troveCollateralRatioAfter = (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;

//         // Make sure Trove is below MCR
//         assertLt(_troveCollateralRatioAfter, troveManager.minimum_collateral_ratio(), "E26");

//         // Finally, liquidate the trove
//         {
//             vm.startPrank(liquidator);
//             uint256[MAX_LIQUIDATIONS] memory _troveIdsToLiquidate;
//             _troveIdsToLiquidate[0] = _troveId;
//             troveManager.liquidate_troves(_troveIdsToLiquidate);
//             vm.stopPrank();
//         }

//         // Check liquidator received no fee (all collateral goes to auction)
//         assertEq(collateralToken.balanceOf(liquidator), 0, "E26a");

//         // Check auction starting price and minimum price
//         {
//             uint256 _expectedStartingPrice = _collateralNeeded * _priceDropToBelowMCR18 * dutchDesk.liquidation_starting_price_buffer_percentage()
//                 / 1e18 / COLLATERAL_TOKEN_PRECISION;
//             assertEq(auction.auctions(0).startingPrice, _expectedStartingPrice, "E27");
//             uint256 _expectedMinimumPrice = _priceDropToBelowMCR18 * dutchDesk.liquidation_minimum_price_buffer_percentage() / WAD;
//             assertEq(auction.auctions(0).minimumPrice, _expectedMinimumPrice, "E28");
//         }

//         // Take the auction
//         takeAuction(0);

//         // Make sure lender got all the borrow tokens back + liquidation fee
//         assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E29");

//         // Make sure liquidator got the collateral
//         assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded, "E30");

//         // Check everything again

//         // Check trove info
//         _trove = troveManager.troves(_troveId);
//         assertEq(_trove.debt, 0, "E31");
//         assertEq(_trove.collateral, 0, "E32");
//         assertEq(_trove.annual_interest_rate, 0, "E33");
//         assertEq(_trove.last_debt_update_time, 0, "E34");
//         assertEq(_trove.last_interest_rate_adj_time, 0, "E35");
//         assertEq(_trove.owner, address(0), "E36");
//         assertEq(_trove.pending_owner, address(0), "E37");
//         assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E38");

//         // Check sorted troves
//         assertTrue(sortedTroves.empty(), "E39");
//         assertEq(sortedTroves.size(), 0, "E40");
//         assertEq(sortedTroves.first(), 0, "E41");
//         assertEq(sortedTroves.last(), 0, "E42");
//         assertFalse(sortedTroves.contains(_troveId), "E43");

//         // Check balances
//         assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E44");
//         assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E45");
//         assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E46");
//         assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E47");
//         assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E48");
//         assertEq(borrowToken.balanceOf(userBorrower), _amount, "E49");

//         // Check global info
//         assertEq(troveManager.total_debt(), 0, "E50");
//         assertEq(troveManager.total_weighted_debt(), 0, "E51");
//         assertEq(troveManager.collateral_balance(), 0, "E52");
//         assertEq(troveManager.zombie_trove_id(), 0, "E53");

//         // Check dutch desk is empty
//         assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E54");
//         assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E55");
//     }

//     // 1. lend
//     // 2. borrow half of available liquidity from 1st borrower
//     // 3. borrow half of available liquidity from 2nd borrower
//     // 4. collateral price drops
//     // 5. liquidate both troves
//     function test_liquidateTroves(
//         uint256 _amount
//     ) public {
//         _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);

//         // Lend some from lender
//         mintAndDepositIntoLender(userLender, _amount);

//         uint256 _halfAmount = _amount / 2;

//         // Calculate how much collateral is needed for the borrow amount
//         uint256 _collateralNeeded =
//             (_halfAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

//         // Calculate expected debt (borrow amount + upfront fee)
//         uint256 _expectedDebt = _halfAmount + troveManager.get_upfront_fee(_halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Open a trove for the first borrower
//         uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Check trove info
//         ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
//         assertEq(_trove.debt, _expectedDebt, "E0");
//         assertEq(_trove.collateral, _collateralNeeded, "E1");
//         assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E2");
//         assertEq(_trove.last_debt_update_time, block.timestamp, "E3");
//         assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E4");
//         assertEq(_trove.owner, userBorrower, "E5");
//         assertEq(_trove.pending_owner, address(0), "E6");
//         assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
//         assertApproxEqRel(
//             (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
//             DEFAULT_TARGET_COLLATERAL_RATIO,
//             1e15,
//             "E8"
//         ); // 0.1%

//         // Check sorted troves
//         assertFalse(sortedTroves.empty(), "E9");
//         assertEq(sortedTroves.size(), 1, "E10");
//         assertEq(sortedTroves.first(), _troveId, "E11");
//         assertEq(sortedTroves.last(), _troveId, "E12");
//         assertTrue(sortedTroves.contains(_troveId), "E13");

//         // Check balances
//         assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E14");
//         assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E15");
//         assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E16");
//         assertApproxEqAbs(borrowToken.balanceOf(address(lender)), _halfAmount, 1, "E17");
//         assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E18");

//         // Check global info
//         assertEq(troveManager.total_debt(), _expectedDebt, "E19");
//         assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E20");
//         assertEq(troveManager.collateral_balance(), _collateralNeeded, "E21");
//         assertEq(troveManager.zombie_trove_id(), 0, "E22");

//         // Check dutch desk is empty
//         assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
//         assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

//         // Open a trove for the second borrower
//         uint256 _anotherTroveId = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Check trove info
//         _trove = troveManager.troves(_anotherTroveId);
//         assertEq(_trove.debt, _expectedDebt, "E25");
//         assertEq(_trove.collateral, _collateralNeeded, "E26");
//         assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E27");
//         assertEq(_trove.last_debt_update_time, block.timestamp, "E28");
//         assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E29");
//         assertEq(_trove.owner, anotherUserBorrower, "E30");
//         assertEq(_trove.pending_owner, address(0), "E31");
//         assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E32");
//         assertApproxEqRel(
//             (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
//             DEFAULT_TARGET_COLLATERAL_RATIO,
//             1e15,
//             "E33"
//         ); // 0.1%

//         // Check sorted troves
//         assertFalse(sortedTroves.empty(), "E34");
//         assertEq(sortedTroves.size(), 2, "E35");
//         assertEq(sortedTroves.first(), _troveId, "E36");
//         assertEq(sortedTroves.last(), _anotherTroveId, "E37");
//         assertTrue(sortedTroves.contains(_troveId), "E38");
//         assertTrue(sortedTroves.contains(_anotherTroveId), "E39");

//         // Check balances
//         assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded * 2, "E40");
//         assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E41");
//         assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E42");
//         assertApproxEqAbs(borrowToken.balanceOf(address(lender)), 0, 1, "E43");
//         assertEq(borrowToken.balanceOf(anotherUserBorrower), _halfAmount, "E44");

//         // Check global info
//         assertEq(troveManager.total_debt(), _expectedDebt * 2, "E45");
//         assertEq(troveManager.total_weighted_debt(), _expectedDebt * 2 * DEFAULT_ANNUAL_INTEREST_RATE, "E46");
//         assertEq(troveManager.collateral_balance(), _collateralNeeded * 2, "E47");
//         assertEq(troveManager.zombie_trove_id(), 0, "E48");

//         // Check dutch desk is empty
//         assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E49");
//         assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E50");

//         // CR = (collateral * price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / debt
//         // So price_at_MCR = MCR * debt * ORACLE_PRICE_SCALE / (collateral * BORROW_TOKEN_PRECISION)
//         // We want to be 1% below MCR
//         uint256 _priceDropToBelowMCR;
//         if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
//             // For low-decimal borrow tokens (e.g., USDC 6d), multiply first to avoid underflow
//             _priceDropToBelowMCR =
//                 troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
//         } else {
//             // For high-decimal borrow tokens (e.g., crvUSD 18d), divide first to avoid overflow
//             _priceDropToBelowMCR =
//                 troveManager.minimum_collateral_ratio() * _trove.debt / (100 * _trove.collateral) * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION * 99;
//         }
//         uint256 _priceDropToBelowMCR18 = _priceDropToBelowMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);

//         // Drop collateral price to put trove below MCR
//         vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceDropToBelowMCR));
//         vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_priceDropToBelowMCR18));

//         // Make sure price actually dropped
//         assertEq(priceOracle.get_price(), _priceDropToBelowMCR, "E51");

//         // Calculate Trove's collateral ratio after price drop
//         uint256 _troveCollateralRatioAfter = (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;

//         // Make sure Trove is below MCR
//         assertLt(_troveCollateralRatioAfter, troveManager.minimum_collateral_ratio(), "E52");

//         // Finally, liquidate the troves
//         {
//             vm.startPrank(liquidator);
//             uint256[MAX_LIQUIDATIONS] memory _troveIdsToLiquidate;
//             _troveIdsToLiquidate[0] = _troveId;
//             _troveIdsToLiquidate[1] = _anotherTroveId;
//             troveManager.liquidate_troves(_troveIdsToLiquidate);
//             vm.stopPrank();
//         }

//         // Check liquidator received no fee (all collateral goes to auction)
//         assertEq(collateralToken.balanceOf(liquidator), 0, "E53");

//         // Check auction starting price and minimum price
//         // Starting price = available * price * STARTING_PRICE_BUFFER_PERCENTAGE / 1e18 / COLLATERAL_TOKEN_PRECISION
//         // Note: both troves liquidated in same tx, so all collateral goes to auction
//         {
//             uint256 _collateralToSell = _collateralNeeded * 2;
//             uint256 _expectedStartingPrice = _collateralToSell * _priceDropToBelowMCR18 * dutchDesk.liquidation_starting_price_buffer_percentage()
//                 / 1e18 / COLLATERAL_TOKEN_PRECISION;
//             assertEq(auction.auctions(0).startingPrice, _expectedStartingPrice, "E54");
//             uint256 _expectedMinimumPrice = _priceDropToBelowMCR18 * dutchDesk.liquidation_minimum_price_buffer_percentage() / WAD;
//             assertEq(auction.auctions(0).minimumPrice, _expectedMinimumPrice, "E55");
//         }

//         // Take the auction
//         takeAuction(0);

//         // Make sure lender got all the borrow tokens back + liquidation fee
//         assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt * 2, "E56");

//         // Make sure liquidator got the collateral
//         assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded * 2, "E57");

//         // Check everything again

//         // Check trove info
//         _trove = troveManager.troves(_troveId);
//         assertEq(_trove.debt, 0, "E58");
//         assertEq(_trove.collateral, 0, "E59");
//         assertEq(_trove.annual_interest_rate, 0, "E60");
//         assertEq(_trove.last_debt_update_time, 0, "E61");
//         assertEq(_trove.last_interest_rate_adj_time, 0, "E62");
//         assertEq(_trove.owner, address(0), "E63");
//         assertEq(_trove.pending_owner, address(0), "E64");
//         assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E65");

//         // Check sorted troves
//         assertTrue(sortedTroves.empty(), "E66");
//         assertEq(sortedTroves.size(), 0, "E67");
//         assertEq(sortedTroves.first(), 0, "E68");
//         assertEq(sortedTroves.last(), 0, "E69");
//         assertFalse(sortedTroves.contains(_troveId), "E70");

//         // Check balances
//         assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E71");
//         assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E72");
//         assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E73");
//         assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E74");
//         assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E75");
//         assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E76");

//         // Check global info
//         assertEq(troveManager.total_debt(), 0, "E77");
//         assertEq(troveManager.total_weighted_debt(), 0, "E78");
//         assertEq(troveManager.collateral_balance(), 0, "E79");
//         assertEq(troveManager.zombie_trove_id(), 0, "E80");

//         // Check dutch desk is empty
//         assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E81");
//         assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E82");

//         // Check everything again for the second trove

//         // Check trove info
//         _trove = troveManager.troves(_anotherTroveId);
//         assertEq(_trove.debt, 0, "E83");
//         assertEq(_trove.collateral, 0, "E84");
//         assertEq(_trove.annual_interest_rate, 0, "E85");
//         assertEq(_trove.last_debt_update_time, 0, "E86");
//         assertEq(_trove.last_interest_rate_adj_time, 0, "E87");
//         assertEq(_trove.owner, address(0), "E88");
//         assertEq(_trove.pending_owner, address(0), "E89");
//         assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E90");

//         // Check sorted troves
//         assertTrue(sortedTroves.empty(), "E91");
//         assertEq(sortedTroves.size(), 0, "E92");
//         assertEq(sortedTroves.first(), 0, "E93");
//         assertEq(sortedTroves.last(), 0, "E94");
//         assertFalse(sortedTroves.contains(_anotherTroveId), "E95");

//         // Check balances
//         assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E96");
//         assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E97");
//         assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E98");
//         assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E99");
//         assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E100");
//         assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E101");

//         // Check global info
//         assertEq(troveManager.total_debt(), 0, "E102");
//         assertEq(troveManager.total_weighted_debt(), 0, "E103");
//         assertEq(troveManager.collateral_balance(), 0, "E104");
//         assertEq(troveManager.zombie_trove_id(), 0, "E105");

//         // Check dutch desk is empty
//         assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E106");
//         assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E107");
//     }

//     // 1. lend
//     // 2. open 2 troves
//     // 3. collateral price drops
//     // 4. liquidate first trove
//     // 5. liquidate second trove (before taking the first auction)
//     // 6. take the auction (should have collateral from both troves - DutchDesk sweeps + settles + re-kicks with all collateral)
//     function test_liquidateTroves_sequentialLiquidations(
//         uint256 _amount
//     ) public {
//         _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);

//         // Lend some from lender
//         mintAndDepositIntoLender(userLender, _amount);

//         uint256 _halfAmount = _amount / 2;

//         // Calculate how much collateral is needed for the borrow amount
//         uint256 _collateralNeeded =
//             (_halfAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

//         // Calculate expected debt (borrow amount + upfront fee)
//         uint256 _expectedDebt = _halfAmount + troveManager.get_upfront_fee(_halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Open first trove
//         uint256 _troveId1 = mintAndOpenTrove(userBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Open second trove
//         uint256 _troveId2 = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _halfAmount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Check trove info for first trove
//         ITroveManager.Trove memory _trove1 = troveManager.troves(_troveId1);
//         assertEq(_trove1.debt, _expectedDebt, "E0");
//         assertEq(_trove1.collateral, _collateralNeeded, "E1");

//         // Check trove info for second trove
//         ITroveManager.Trove memory _trove2 = troveManager.troves(_troveId2);
//         assertEq(_trove2.debt, _expectedDebt, "E2");
//         assertEq(_trove2.collateral, _collateralNeeded, "E3");

//         // Check dutch desk is empty
//         assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E4");
//         assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E5");

//         // CR = collateral * price / debt, so price_at_MCR = MCR * debt / collateral
//         // We want to be 1% below MCR
//         uint256 _priceDropToBelowMCR;
//         if (BORROW_TOKEN_PRECISION < COLLATERAL_TOKEN_PRECISION) {
//             // For low-decimal borrow tokens (e.g., USDC 6d), multiply first to avoid underflow
//             _priceDropToBelowMCR = troveManager.minimum_collateral_ratio() * _trove1.debt * ORACLE_PRICE_SCALE * 99
//                 / (100 * _trove1.collateral * BORROW_TOKEN_PRECISION);
//         } else {
//             // For high-decimal borrow tokens (e.g., crvUSD 18d), divide first to avoid overflow
//             _priceDropToBelowMCR =
//                 troveManager.minimum_collateral_ratio() * _trove1.debt * 99 / 100 / _trove1.collateral * ORACLE_PRICE_SCALE / BORROW_TOKEN_PRECISION;
//         }
//         uint256 _priceDropToBelowMCR18 = _priceDropToBelowMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);

//         // Drop collateral price to put both troves below MCR
//         vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceDropToBelowMCR));
//         vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_priceDropToBelowMCR18));

//         // Make sure price actually dropped
//         assertEq(priceOracle.get_price(), _priceDropToBelowMCR, "E6");

//         // Make sure both troves are below MCR
//         assertLt(
//             (_trove1.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove1.debt,
//             troveManager.minimum_collateral_ratio(),
//             "E7"
//         );
//         assertLt(
//             (_trove2.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove2.debt,
//             troveManager.minimum_collateral_ratio(),
//             "E8"
//         );

//         // Liquidate the first trove
//         vm.startPrank(liquidator);
//         uint256[MAX_LIQUIDATIONS] memory _troveIdsToLiquidate;
//         _troveIdsToLiquidate[0] = _troveId1;
//         troveManager.liquidate_troves(_troveIdsToLiquidate);
//         vm.stopPrank();

//         // Check liquidator received no fee (all collateral goes to auction)
//         assertEq(collateralToken.balanceOf(liquidator), 0, "E9");

//         // Check auction 0 has all collateral from first trove
//         // uint256 _auctionId0 = 0;
//         {
//             uint256 _collateralInAuction = _collateralNeeded;
//             assertTrue(auction.is_active(0), "E10");
//             assertEq(auction.get_available_amount(0), _collateralInAuction, "E11");
//             assertEq(collateralToken.balanceOf(address(auction)), _collateralInAuction, "E12");

//             // Check auction starting price and minimum price after first liquidation
//             assertEq(
//                 auction.auctions(0).startingPrice,
//                 _collateralInAuction * _priceDropToBelowMCR18 * dutchDesk.liquidation_starting_price_buffer_percentage() / 1e18
//                     / COLLATERAL_TOKEN_PRECISION,
//                 "E13"
//             );
//             assertEq(auction.auctions(0).minimumPrice, _priceDropToBelowMCR18 * dutchDesk.liquidation_minimum_price_buffer_percentage() / WAD, "E14");
//         }

//         // Check first trove is liquidated
//         _trove1 = troveManager.troves(_troveId1);
//         assertEq(uint256(troveManager.troves(_troveId1).status), uint256(ITroveManager.Status.liquidated), "E15");

//         // Check second trove is still active
//         _trove2 = troveManager.troves(_troveId2);
//         assertEq(uint256(_trove2.status), uint256(ITroveManager.Status.active), "E16");

//         // Liquidate the second trove (before taking the first auction)
//         // In new architecture, this creates a separate auction with ID 1
//         vm.startPrank(liquidator);
//         _troveIdsToLiquidate[0] = _troveId2;
//         troveManager.liquidate_troves(_troveIdsToLiquidate);
//         vm.stopPrank();

//         // Check liquidator received no fees (all collateral goes to auction)
//         assertEq(collateralToken.balanceOf(liquidator), 0, "E17");

//         // Check second trove is now liquidated
//         _trove2 = troveManager.troves(_troveId2);
//         assertEq(uint256(_trove2.status), uint256(ITroveManager.Status.liquidated), "E18");

//         // Check auction 1 has all collateral from second trove (separate auction)
//         // uint256 _auctionId1 = 1;
//         {
//             uint256 _collateralInAuction = _collateralNeeded;
//             assertTrue(auction.is_active(1), "E19");
//             assertEq(auction.get_available_amount(1), _collateralInAuction, "E20");
//             assertEq(collateralToken.balanceOf(address(auction)), _collateralInAuction * 2, "E21");

//             // Check auction 0 is still active with first trove's collateral
//             assertTrue(auction.is_active(0), "E22");
//             assertEq(auction.get_available_amount(0), _collateralInAuction, "E23");
//         }

//         // Take both auctions
//         takeAuction(0);
//         takeAuction(1);

//         // Both auctions should be empty now
//         assertEq(collateralToken.balanceOf(address(auction)), 0, "E24");
//         assertFalse(auction.is_active(0), "E25");
//         assertFalse(auction.is_active(1), "E26");

//         // Make sure lender got all the borrow tokens back + liquidation fees
//         assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt * 2, "E27");

//         // Make sure liquidator got all the collateral (fees + auction proceeds)
//         assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded * 2, "E28");

//         // Check dutch desk is empty
//         assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E29");
//         assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E30");

//         // Check global info
//         assertEq(troveManager.total_debt(), 0, "E31");
//         assertEq(troveManager.total_weighted_debt(), 0, "E32");
//         assertEq(troveManager.collateral_balance(), 0, "E33");
//     }

//     function test_liquidateTroves_emptyList() public {
//         // Make sure we always fail when no trove ids are passed
//         uint256[MAX_LIQUIDATIONS] memory _troveIdsToLiquidate;
//         vm.expectRevert("!trove_ids");
//         troveManager.liquidate_troves(_troveIdsToLiquidate);
//     }

//     function test_liquidateTroves_nonExistentTrove(
//         uint256 _nonExistentTroveId
//     ) public {
//         _nonExistentTroveId = bound(_nonExistentTroveId, 1, type(uint256).max);
//         // Make sure we always fail when a non-existent trove is passed
//         uint256[MAX_LIQUIDATIONS] memory _troveIdsToLiquidate;
//         _troveIdsToLiquidate[0] = _nonExistentTroveId;
//         vm.expectRevert("!active or zombie");
//         troveManager.liquidate_troves(_troveIdsToLiquidate);
//     }

//     function test_liquidateTroves_aboveMCR(
//         uint256 _amount
//     ) public {
//         _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

//         // Lend some from lender
//         mintAndDepositIntoLender(userLender, _amount);

//         // Calculate how much collateral is needed for the borrow amount
//         uint256 _collateralNeeded =
//             (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

//         // Open a trove
//         uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Make sure we cannot liquidate a trove that is above MCR
//         uint256[MAX_LIQUIDATIONS] memory _troveIdsToLiquidate;
//         _troveIdsToLiquidate[0] = _troveId;
//         vm.expectRevert("!collateral_ratio");
//         troveManager.liquidate_troves(_troveIdsToLiquidate);
//     }

//     function test_liquidateGas() public {
//         uint256 _amount = troveManager.min_debt() * BORROW_TOKEN_PRECISION;

//         mintAndDepositIntoLender(userLender, _amount);

//         uint256 _collateralNeeded =
//             (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

//         uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

//         // Drop price below MCR
//         ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
//         uint256 _priceDropToBelowMCR =
//             troveManager.minimum_collateral_ratio() * _trove.debt * ORACLE_PRICE_SCALE * 99 / (100 * _trove.collateral * BORROW_TOKEN_PRECISION);
//         uint256 _priceDropToBelowMCR18 = _priceDropToBelowMCR * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);

//         vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_priceDropToBelowMCR));
//         vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_priceDropToBelowMCR18));

//         uint256[MAX_LIQUIDATIONS] memory _troveIds;
//         _troveIds[0] = _troveId;

//         uint256 _gasBefore = gasleft();
//         vm.prank(liquidator);
//         troveManager.liquidate_troves(_troveIds);
//         uint256 _gasUsed = _gasBefore - gasleft();

//         console2.log("Gas used to liquidate 1 trove:", _gasUsed);
//     }

// }
