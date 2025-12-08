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

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

        // CR = collateral * price / debt, so price_at_MCR = MCR * debt / collateral
        // We want to be 1% below MCR
        uint256 _priceDropToBelowMCR = troveManager.MINIMUM_COLLATERAL_RATIO() * _trove.debt * 99 / 100 / _trove.collateral;

        // Drop collateral price to put trove below MCR
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracle.price.selector), abi.encode(_priceDropToBelowMCR));

        // Make sure price actually dropped
        assertEq(priceOracle.price(), _priceDropToBelowMCR, "E25");

        // Calculate Trove's collateral ratio after price drop
        uint256 _troveCollateralRatioAfter = _trove.collateral * priceOracle.price() / _trove.debt;

        // Make sure Trove is below MCR
        assertLt(_troveCollateralRatioAfter, troveManager.MINIMUM_COLLATERAL_RATIO(), "E26");

        // Finally, liquidate the trove
        vm.startPrank(liquidator);
        uint256[MAX_LIQUIDATION_BATCH_SIZE] memory _troveIdsToLiquidate;
        _troveIdsToLiquidate[0] = _troveId;
        troveManager.liquidate_troves(_troveIdsToLiquidate);
        vm.stopPrank();

        // Check auction starting price and minimum price
        address _liquidationAuction = dutchDesk.LIQUIDATION_AUCTION();
        // Starting price = available * price / WAD * STARTING_PRICE_BUFFER_PERCENTAGE / WAD / WAD
        uint256 _expectedStartingPrice = _collateralNeeded * _priceDropToBelowMCR / 1e18 * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18;
        assertEq(IAuction(_liquidationAuction).startingPrice(), _expectedStartingPrice, "E27");
        // Minimum price = price * MINIMUM_PRICE_BUFFER_PERCENTAGE / WAD
        uint256 _expectedMinimumPrice = _priceDropToBelowMCR * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18;
        assertEq(IAuction(_liquidationAuction).minimumPrice(), _expectedMinimumPrice, "E28");

        // Take the auction
        takeAuction(_liquidationAuction);

        // Make sure lender got all the borrow tokens back + liquidation fee
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E29");

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

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E54");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E55");
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

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E23");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E24");

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

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E49");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E50");

        // CR = collateral * price / debt, so price_at_MCR = MCR * debt / collateral
        // We want to be 1% below MCR
        uint256 _priceDropToBelowMCR = troveManager.MINIMUM_COLLATERAL_RATIO() * _trove.debt * 99 / 100 / _trove.collateral;

        // Drop collateral price to put trove below MCR
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracle.price.selector), abi.encode(_priceDropToBelowMCR));

        // Make sure price actually dropped
        assertEq(priceOracle.price(), _priceDropToBelowMCR, "E51");

        // Calculate Trove's collateral ratio after price drop
        uint256 _troveCollateralRatioAfter = _trove.collateral * priceOracle.price() / _trove.debt;

        // Make sure Trove is below MCR
        assertLt(_troveCollateralRatioAfter, troveManager.MINIMUM_COLLATERAL_RATIO(), "E52");

        // Finally, liquidate the troves
        vm.startPrank(liquidator);
        uint256[MAX_LIQUIDATION_BATCH_SIZE] memory _troveIdsToLiquidate;
        _troveIdsToLiquidate[0] = _troveId;
        _troveIdsToLiquidate[1] = _anotherTroveId;
        troveManager.liquidate_troves(_troveIdsToLiquidate);
        vm.stopPrank();

        // Check auction starting price and minimum price
        address _liquidationAuction = dutchDesk.LIQUIDATION_AUCTION();
        // Starting price = available * price / WAD * STARTING_PRICE_BUFFER_PERCENTAGE / WAD / WAD
        // Note: both troves liquidated in same tx, so collateral = _collateralNeeded * 2
        uint256 _expectedStartingPrice =
            _collateralNeeded * 2 * _priceDropToBelowMCR / 1e18 * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18;
        assertEq(IAuction(_liquidationAuction).startingPrice(), _expectedStartingPrice, "E53");
        // Minimum price = price * MINIMUM_PRICE_BUFFER_PERCENTAGE / WAD
        uint256 _expectedMinimumPrice = _priceDropToBelowMCR * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18;
        assertEq(IAuction(_liquidationAuction).minimumPrice(), _expectedMinimumPrice, "E54");

        // Take the auction
        takeAuction(_liquidationAuction);

        // Make sure lender got all the borrow tokens back + liquidation fee
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt * 2, "E55");

        // Make sure liquidator got the collateral
        assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded * 2, "E56");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E57");
        assertEq(_trove.collateral, 0, "E58");
        assertEq(_trove.annual_interest_rate, 0, "E59");
        assertEq(_trove.last_debt_update_time, 0, "E60");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E61");
        assertEq(_trove.owner, address(0), "E62");
        assertEq(_trove.pending_owner, address(0), "E63");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E64");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E65");
        assertEq(sortedTroves.size(), 0, "E66");
        assertEq(sortedTroves.first(), 0, "E67");
        assertEq(sortedTroves.last(), 0, "E68");
        assertFalse(sortedTroves.contains(_troveId), "E69");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E70");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E71");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E72");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E73");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E74");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E75");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E76");
        assertEq(troveManager.total_weighted_debt(), 0, "E77");
        assertEq(troveManager.collateral_balance(), 0, "E78");
        assertEq(troveManager.zombie_trove_id(), 0, "E79");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E80");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E81");

        // Check everything again for the second trove

        // Check trove info
        _trove = troveManager.troves(_anotherTroveId);
        assertEq(_trove.debt, 0, "E82");
        assertEq(_trove.collateral, 0, "E83");
        assertEq(_trove.annual_interest_rate, 0, "E84");
        assertEq(_trove.last_debt_update_time, 0, "E85");
        assertEq(_trove.last_interest_rate_adj_time, 0, "E86");
        assertEq(_trove.owner, address(0), "E87");
        assertEq(_trove.pending_owner, address(0), "E88");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.liquidated), "E89");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E90");
        assertEq(sortedTroves.size(), 0, "E91");
        assertEq(sortedTroves.first(), 0, "E92");
        assertEq(sortedTroves.last(), 0, "E93");
        assertFalse(sortedTroves.contains(_anotherTroveId), "E94");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), 0, "E95");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E96");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E97");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E98");
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt, "E99");
        assertEq(borrowToken.balanceOf(userBorrower), _halfAmount, "E100");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E101");
        assertEq(troveManager.total_weighted_debt(), 0, "E102");
        assertEq(troveManager.collateral_balance(), 0, "E103");
        assertEq(troveManager.zombie_trove_id(), 0, "E104");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E105");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E106");
    }

    // 1. lend
    // 2. open 2 troves
    // 3. collateral price drops
    // 4. liquidate first trove
    // 5. liquidate second trove (before taking the first auction)
    // 6. take the auction (should have collateral from both troves - DutchDesk sweeps + settles + re-kicks with all collateral)
    function test_liquidateTroves_sequentialLiquidations(
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
        uint256 _priceDropToBelowMCR = troveManager.MINIMUM_COLLATERAL_RATIO() * _trove1.debt * 99 / 100 / _trove1.collateral;

        // Drop collateral price to put both troves below MCR
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracle.price.selector), abi.encode(_priceDropToBelowMCR));

        // Make sure price actually dropped
        assertEq(priceOracle.price(), _priceDropToBelowMCR, "E6");

        // Make sure both troves are below MCR
        assertLt(_trove1.collateral * priceOracle.price() / _trove1.debt, troveManager.MINIMUM_COLLATERAL_RATIO(), "E7");
        assertLt(_trove2.collateral * priceOracle.price() / _trove2.debt, troveManager.MINIMUM_COLLATERAL_RATIO(), "E8");

        // Liquidate the first trove
        vm.startPrank(liquidator);
        uint256[MAX_LIQUIDATION_BATCH_SIZE] memory _troveIdsToLiquidate;
        _troveIdsToLiquidate[0] = _troveId1;
        troveManager.liquidate_troves(_troveIdsToLiquidate);
        vm.stopPrank();

        // Check auction has collateral from first trove
        assertTrue(IAuction(dutchDesk.LIQUIDATION_AUCTION()).isActive(address(collateralToken)), "E9");
        assertEq(IAuction(dutchDesk.LIQUIDATION_AUCTION()).available(address(collateralToken)), _collateralNeeded, "E10");
        assertEq(collateralToken.balanceOf(dutchDesk.LIQUIDATION_AUCTION()), _collateralNeeded, "E11");

        // Check auction starting price and minimum price after first liquidation
        // Starting price = available * price / WAD * STARTING_PRICE_BUFFER_PERCENTAGE / WAD / WAD
        assertEq(
            IAuction(dutchDesk.LIQUIDATION_AUCTION()).startingPrice(),
            _collateralNeeded * _priceDropToBelowMCR / 1e18 * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18,
            "E12"
        );
        // Minimum price = price * MINIMUM_PRICE_BUFFER_PERCENTAGE / WAD
        uint256 _expectedMinimumPrice = _priceDropToBelowMCR * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18;
        assertEq(
            IAuction(dutchDesk.LIQUIDATION_AUCTION()).minimumPrice(), _priceDropToBelowMCR * dutchDesk.MINIMUM_PRICE_BUFFER_PERCENTAGE() / 1e18, "E13"
        );

        // Check first trove is liquidated
        _trove1 = troveManager.troves(_troveId1);
        assertEq(uint256(_trove1.status), uint256(ITroveManager.Status.liquidated), "E14");

        // Check second trove is still active
        _trove2 = troveManager.troves(_troveId2);
        assertEq(uint256(_trove2.status), uint256(ITroveManager.Status.active), "E15");

        // Liquidate the second trove (before taking the first auction)
        // DutchDesk._kick will sweep + settle the first auction and kick a new one with all collateral
        vm.startPrank(liquidator);
        _troveIdsToLiquidate[0] = _troveId2;
        troveManager.liquidate_troves(_troveIdsToLiquidate);
        vm.stopPrank();

        // Check second trove is now liquidated
        _trove2 = troveManager.troves(_troveId2);
        assertEq(uint256(_trove2.status), uint256(ITroveManager.Status.liquidated), "E16");

        // Check auction now has collateral from BOTH troves (sweep + settle + re-kick with combined amount)
        assertTrue(IAuction(dutchDesk.LIQUIDATION_AUCTION()).isActive(address(collateralToken)), "E17");
        assertEq(IAuction(dutchDesk.LIQUIDATION_AUCTION()).available(address(collateralToken)), _collateralNeeded * 2, "E18");
        assertEq(collateralToken.balanceOf(dutchDesk.LIQUIDATION_AUCTION()), _collateralNeeded * 2, "E19");

        // Check auction starting price and minimum price after second liquidation (combined collateral)
        uint256 _expectedStartingPrice2 =
            _collateralNeeded * 2 * _priceDropToBelowMCR / 1e18 * dutchDesk.STARTING_PRICE_BUFFER_PERCENTAGE() / 1e18 / 1e18;
        assertEq(IAuction(dutchDesk.LIQUIDATION_AUCTION()).startingPrice(), _expectedStartingPrice2, "E20");
        // Minimum price should be the same (based on collateral price, not amount)
        assertEq(IAuction(dutchDesk.LIQUIDATION_AUCTION()).minimumPrice(), _expectedMinimumPrice, "E21");

        // Take the auction (takes all collateral from both troves)
        takeAuction(dutchDesk.LIQUIDATION_AUCTION());

        // Auction should be empty now
        assertEq(collateralToken.balanceOf(dutchDesk.LIQUIDATION_AUCTION()), 0, "E22");
        assertFalse(IAuction(dutchDesk.LIQUIDATION_AUCTION()).isActive(address(collateralToken)), "E23");

        // Make sure lender got all the borrow tokens back + liquidation fees
        assertGe(borrowToken.balanceOf(address(lender)), _expectedDebt * 2, "E24");

        // Make sure liquidator got all the collateral
        assertEq(collateralToken.balanceOf(liquidator), _collateralNeeded * 2, "E25");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E26");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E27");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E28");
        assertEq(troveManager.total_weighted_debt(), 0, "E29");
        assertEq(troveManager.collateral_balance(), 0, "E30");
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
