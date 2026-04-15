// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract LendTests is Base {

    function setUp() public override {
        Base.setUp();

        // Set `profitMaxUnlockTime` to 0
        vm.prank(address(daddy));
        lender.setProfitMaxUnlockTime(0);

        // Set fees to 0
        vm.prank(address(daddy));
        lender.setPerformanceFee(0);

        // Adjust fuzz
        maxFuzzAmount = 10_000 ether;
        if (BORROW_TOKEN_PRECISION < 1e18) {
            uint256 _decimalsDiff = 1e18 / BORROW_TOKEN_PRECISION;
            maxFuzzAmount = maxFuzzAmount / _decimalsDiff;
        }
    }

    function test_setup() public {
        assertEq(address(lender.TROVE_MANAGER()), address(troveManager), "E1");
        assertEq(lender.depositLimit(), type(uint256).max, "E2");
        assertEq(lender.availableWithdrawLimit(userLender), type(uint256).max, "E3");
        assertEq(lender.availableDepositLimit(userLender), type(uint256).max, "E4");
        assertEq(lender.name(), "Flex yvWETH-2/USDC Lender", "E5");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip some time, check we earn interest
    // 4. withdraw everything (+ profit)
    function test_lend(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        assertEq(lender.totalAssets(), _amount, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _upfrontFee = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedDebt = _amount + _upfrontFee;

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E1");
        assertEq(_trove.collateral, _collateralNeeded, "E2");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E3");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E4");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E5");
        assertEq(_trove.owner, userBorrower, "E6");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E8"
        ); // 0.1%

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

        // Skip some time, calculate expected interest
        uint256 _daysToSkip = 90 days;
        uint256 _expectedProfit = _upfrontFee + _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * _daysToSkip / 365 days / BORROW_TOKEN_PRECISION;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - ((_amount + _expectedProfit) * ORACLE_PRICE_SCALE / priceOracle.get_price());

        // Sanity check
        assertGt(_expectedProfit, 0, "E25");

        // Earn Interest
        skip(_daysToSkip);

        // Report profit
        (uint256 _profit, uint256 _loss) = IKeeper(lenderFactory.KEEPER()).report(address(lender));

        // Check return Values
        assertApproxEqAbs(_profit, _expectedProfit, 2, "E26");
        assertEq(_loss, 0, "E27");

        uint256 _balanceBefore = borrowToken.balanceOf(userLender);

        // Withdraw all funds
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Check an auction was created
        uint256 _auctionId = 0;
        assertTrue(auction.is_active(_auctionId), "E28");
        assertGt(auction.get_available_amount(_auctionId), 0, "E29");

        // Take the auction
        takeAuction(_auctionId);

        // Auction should be empty now
        assertEq(auction.get_available_amount(_auctionId), 0, "E30");
        assertFalse(auction.is_active(_auctionId), "E31");

        // profit > slippage
        assertGt(borrowToken.balanceOf(userLender), _balanceBefore + _amount, "E32");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E33");
        assertApproxEqRel(_trove.collateral, _expectedCollateralAfterRedemption, 1e16, "E34"); // 1%
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E35");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E36");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime - _daysToSkip, "E37");
        assertEq(_trove.owner, userBorrower, "E38");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E39");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E40");
        assertEq(sortedTroves.size(), 0, "E41");
        assertEq(sortedTroves.first(), 0, "E42");
        assertEq(sortedTroves.last(), 0, "E43");
        assertFalse(sortedTroves.contains(_troveId), "E44");

        // Check balances
        assertApproxEqRel(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, 1e16, "E45"); // 1%
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E46");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E47");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E48");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E49");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E50");

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), 0, 2, "E51");
        assertEq(troveManager.total_weighted_debt(), 0, "E52");
        assertApproxEqRel(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, 1e16, "E53"); // 1%
        assertEq(troveManager.zombie_trove_id(), 0, "E54");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E55");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E56");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip some time, check we earn interest
    // 4. withdraw without reporting, so borrower has tiny amount of debt left (< min debt)
    // 5. make sure borrower is now zombie and has tiny debt left
    function test_lend_noReport(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        assertEq(lender.totalAssets(), _amount, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _upfrontFee = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedDebt = _amount + _upfrontFee;

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E1");
        assertEq(_trove.collateral, _collateralNeeded, "E2");
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E3");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E4");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp, "E5");
        assertEq(_trove.owner, userBorrower, "E6");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E7");
        assertApproxEqRel(
            (_trove.collateral * priceOracle.get_price() / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt,
            DEFAULT_TARGET_COLLATERAL_RATIO,
            1e15,
            "E8"
        ); // 0.1%

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

        // Skip some time, calculate expected interest
        uint256 _daysToSkip = 90 days;

        // Earn Interest
        skip(_daysToSkip);

        // Calculate actual debt after interest accrual
        uint256 _debtAfterInterest = troveManager.get_trove_debt_after_interest(_troveId);
        console2.log("_debtAfterInterest:", _debtAfterInterest);
        console2.log("_amount:", _amount);
        uint256 _expectedProfit = _debtAfterInterest - _amount;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_amount * ORACLE_PRICE_SCALE / priceOracle.get_price());

        // Sanity check
        assertGt(_expectedProfit, 0, "E25");

        uint256 _balanceBefore = borrowToken.balanceOf(userLender);

        // Withdraw all funds
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // Cache the expected time because it will be skipped during the auction
        uint256 _expectedTime = block.timestamp;

        // Check an auction was created
        uint256 _auctionId = 0;
        assertTrue(auction.is_active(_auctionId), "E26");
        assertGt(auction.get_available_amount(_auctionId), 0, "E27");

        // Take the auction
        takeAuction(_auctionId);

        // Auction should be empty now
        assertEq(auction.get_available_amount(_auctionId), 0, "E28");
        assertFalse(auction.is_active(_auctionId), "E29");

        // No report, no profit, loss bc `takeAuction` pricing is not perfect
        assertApproxEqRel(borrowToken.balanceOf(userLender), _balanceBefore + _amount, 5e15, "E30"); // 0.5%

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedProfit, "E31");
        assertApproxEqRel(_trove.collateral, _expectedCollateralAfterRedemption, 5e15, "E32"); // 0.5%
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E33");
        assertEq(_trove.last_debt_update_time, _expectedTime, "E34");
        assertEq(_trove.last_interest_rate_adj_time, _expectedTime - _daysToSkip, "E35");
        assertEq(_trove.owner, userBorrower, "E36");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E37");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E38");
        assertEq(sortedTroves.size(), 0, "E39");
        assertEq(sortedTroves.first(), 0, "E40");
        assertEq(sortedTroves.last(), 0, "E41");
        assertFalse(sortedTroves.contains(_troveId), "E42");

        // Check balances
        assertApproxEqRel(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, 5e15, "E43"); // 0.5%
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E44");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E45");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E46");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E47");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E48");

        // Check global info
        assertApproxEqAbs(troveManager.total_debt(), _expectedProfit, 2, "E49");
        assertEq(troveManager.total_weighted_debt(), _expectedProfit * DEFAULT_ANNUAL_INTEREST_RATE, "E50");
        assertApproxEqRel(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, 5e15, "E51"); // 0.5%
        assertEq(troveManager.zombie_trove_id(), _troveId, "E52");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E53");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E54");
    }

    // Test that multiple auctions are created for concurrent redemptions
    function test_lend_multipleAuctions(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 10, maxFuzzAmount);

        // Bump up interest rate
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend from two lenders
        mintAndDepositIntoLender(userLender, _amount);
        mintAndDepositIntoLender(anotherUserBorrower, _amount);

        // Open a single trove with enough debt for both lenders
        uint256 _collateralNeeded =
            (_amount * 2 * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(userBorrower, _collateralNeeded, _amount * 2, DEFAULT_ANNUAL_INTEREST_RATE);

        // First lender withdraws - creates auction 0
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        uint256 _auctionId0 = 0;
        assertTrue(auction.is_active(_auctionId0), "E0");

        // Second lender withdraws while first auction is active - creates auction 1
        vm.prank(anotherUserBorrower);
        lender.redeem(_amount, anotherUserBorrower, anotherUserBorrower);

        uint256 _auctionId1 = 1;
        assertTrue(auction.is_active(_auctionId1), "E1");

        // Take both auctions
        takeAuction(_auctionId0);
        takeAuction(_auctionId1);

        // Both auctions should be empty
        assertFalse(auction.is_active(_auctionId0), "E2");
        assertFalse(auction.is_active(_auctionId1), "E3");

        // Check dutch desk is empty
        assertEq(borrowToken.balanceOf(address(dutchDesk)), 0, "E4");
        assertEq(collateralToken.balanceOf(address(dutchDesk)), 0, "E5");
    }

    // 1. lend
    // 2. 3 borrowers borrow all liquidity
    // 3. lender withdraws all liquidity and redeems all 3 borrowers in the same tx
    function test_lend_redeemMultipleBorrowers() public {
        uint256 _minDebt = troveManager.min_debt();
        uint256 _lenderDeposit = _minDebt * 3;

        // Lend
        mintAndDepositIntoLender(userLender, _lenderDeposit);

        // 3 borrowers borrow all liquidity
        for (uint256 i = 0; i < 3; i++) {
            uint256 _collateralNeeded =
                (_minDebt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

            address _borrower = address(uint160(i + 1000));
            mintAndOpenTrove(_borrower, _collateralNeeded, _minDebt, DEFAULT_ANNUAL_INTEREST_RATE);
        }

        // Sanity checks
        assertEq(sortedTroves.size(), 3, "E0");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E1");

        // Report profit
        IKeeper(lenderFactory.KEEPER()).report(address(lender));

        // Lender withdraws all - should redeem all 3 borrowers
        vm.prank(userLender);
        lender.redeem(_lenderDeposit, userLender, userLender);

        // Take auction
        uint256 _auctionId = 0;
        takeAuction(_auctionId);

        // All 3 troves should be zombies
        assertEq(sortedTroves.size(), 0, "E2");
        assertEq(troveManager.total_debt(), 0, "E3");
    }

    function test_setDepositLimit(
        uint256 _depositLimit
    ) public {
        vm.prank(address(daddy));
        lender.setDepositLimit(_depositLimit);

        assertEq(lender.depositLimit(), _depositLimit, "E0");
    }

    function test_setDepositLimit_wrongCaller(
        uint256 _depositLimit,
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != address(daddy));

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        lender.setDepositLimit(_depositLimit);
    }

}
