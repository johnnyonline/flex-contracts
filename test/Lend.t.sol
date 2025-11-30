// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract LendTests is Base {

    function setUp() public override {
        Base.setUp();

        // Set `profitMaxUnlockTime` to 0
        vm.prank(management);
        lender.setProfitMaxUnlockTime(0);

        // Set fees to 0
        vm.prank(management);
        lender.setPerformanceFee(0);

        // Limit fuzz amount to decrease slippage
        maxFuzzAmount = 10_000 ether;
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip some time, check we earn interest
    // 4. withdraw everything (+ profit)
    function test_lend(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        assertEq(lender.totalAssets(), _amount, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

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
        assertEq(_trove.pending_owner, address(0), "E7");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E8");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E9"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E10");
        assertEq(sortedTroves.size(), 1, "E11");
        assertEq(sortedTroves.first(), _troveId, "E12");
        assertEq(sortedTroves.last(), _troveId, "E13");
        assertTrue(sortedTroves.contains(_troveId), "E14");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E15");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E16");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E17");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E18");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E19");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E20");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E21");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E22");
        assertEq(troveManager.zombie_trove_id(), 0, "E23");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E24");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E25");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E26");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E27");

        // Skip some time, calculate expected interest
        uint256 _daysToSkip = 90 days;
        uint256 _expectedProfit = _upfrontFee + _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * _daysToSkip / 365 days / 1e18;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - ((_amount + _expectedProfit) * 1e18 / priceOracle.price());

        // Sanity check
        assertGt(_expectedProfit, 0, "E28");

        // Earn Interest
        skip(_daysToSkip);

        // Report profit
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = lender.report();

        // Check return Values
        assertEq(_profit, _expectedProfit, "E29");
        assertEq(_loss, 0, "E30");

        uint256 _balanceBefore = borrowToken.balanceOf(userLender);

        // Withdraw all funds
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // profit > slippage
        assertGt(borrowToken.balanceOf(userLender), _balanceBefore + _amount, "E31");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, 0, "E32");
        assertApproxEqRel(_trove.collateral, _expectedCollateralAfterRedemption, 5e15, "E33"); // 0.5%
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E34");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E35");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp - _daysToSkip, "E36");
        assertEq(_trove.owner, userBorrower, "E37");
        assertEq(_trove.pending_owner, address(0), "E38");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E39");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E40");
        assertEq(sortedTroves.size(), 0, "E41");
        assertEq(sortedTroves.first(), 0, "E42");
        assertEq(sortedTroves.last(), 0, "E43");
        assertFalse(sortedTroves.contains(_troveId), "E44");

        // Check balances
        assertApproxEqRel(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, 5e15, "E45"); // 0.5%
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E46");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E47");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E48");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E49");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E50");

        // Check global info
        assertEq(troveManager.total_debt(), 0, "E51");
        assertEq(troveManager.total_weighted_debt(), 0, "E52");
        assertApproxEqRel(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, 5e15, "E53"); // 0.5%
        assertEq(troveManager.zombie_trove_id(), 0, "E54");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E55");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E56");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E57");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E58");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip some time, check we earn interest
    // 4. withdraw without reporting, so borrower has tiny amount of debt left (< min debt)
    // 5. make sure borrower is now zombie and has tiny debt left
    function test_lend_noReport(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        assertEq(lender.totalAssets(), _amount, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

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
        assertEq(_trove.pending_owner, address(0), "E7");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E8");
        assertApproxEqRel(_trove.collateral * priceOracle.price() / _trove.debt, DEFAULT_TARGET_COLLATERAL_RATIO, 1e15, "E9"); // 0.1%

        // Check sorted troves
        assertFalse(sortedTroves.empty(), "E10");
        assertEq(sortedTroves.size(), 1, "E11");
        assertEq(sortedTroves.first(), _troveId, "E12");
        assertEq(sortedTroves.last(), _troveId, "E13");
        assertTrue(sortedTroves.contains(_troveId), "E14");

        // Check balances
        assertEq(collateralToken.balanceOf(address(troveManager)), _collateralNeeded, "E15");
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E16");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E17");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E18");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E19");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedDebt, "E20");
        assertEq(troveManager.total_weighted_debt(), _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE, "E21");
        assertEq(troveManager.collateral_balance(), _collateralNeeded, "E22");
        assertEq(troveManager.zombie_trove_id(), 0, "E23");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E24");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E25");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E26");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E27");

        // Skip some time, calculate expected interest
        uint256 _daysToSkip = 90 days;
        uint256 _expectedProfit = _upfrontFee + _expectedDebt * DEFAULT_ANNUAL_INTEREST_RATE * _daysToSkip / 365 days / 1e18;

        // Calculate expected collateral after redemption
        uint256 _expectedCollateralAfterRedemption = _collateralNeeded - (_amount * 1e18 / priceOracle.price());

        // Sanity check
        assertGt(_expectedProfit, 0, "E28");

        // Earn Interest
        skip(_daysToSkip);

        uint256 _balanceBefore = borrowToken.balanceOf(userLender);

        // Withdraw all funds
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // No report, no profit, loss bc slippage
        assertLt(borrowToken.balanceOf(userLender), _balanceBefore + _amount, "E29");

        // Check everything again

        // Check trove info
        _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedProfit, "E30");
        assertApproxEqRel(_trove.collateral, _expectedCollateralAfterRedemption, 5e15, "E31"); // 0.5%
        assertEq(_trove.annual_interest_rate, DEFAULT_ANNUAL_INTEREST_RATE, "E32");
        assertEq(_trove.last_debt_update_time, block.timestamp, "E33");
        assertEq(_trove.last_interest_rate_adj_time, block.timestamp - _daysToSkip, "E34");
        assertEq(_trove.owner, userBorrower, "E35");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E36");

        // Check sorted troves
        assertTrue(sortedTroves.empty(), "E37");
        assertEq(sortedTroves.size(), 0, "E38");
        assertEq(sortedTroves.first(), 0, "E39");
        assertEq(sortedTroves.last(), 0, "E40");
        assertFalse(sortedTroves.contains(_troveId), "E41");

        // Check balances
        assertApproxEqRel(collateralToken.balanceOf(address(troveManager)), _expectedCollateralAfterRedemption, 5e15, "E42"); // 0.5%
        assertEq(collateralToken.balanceOf(address(troveManager)), troveManager.collateral_balance(), "E43");
        assertEq(collateralToken.balanceOf(address(userBorrower)), 0, "E44");
        assertEq(borrowToken.balanceOf(address(troveManager)), 0, "E45");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E46");
        assertEq(borrowToken.balanceOf(userBorrower), _amount, "E47");

        // Check global info
        assertEq(troveManager.total_debt(), _expectedProfit, "E48");
        assertEq(troveManager.total_weighted_debt(), _expectedProfit * DEFAULT_ANNUAL_INTEREST_RATE, "E49");
        assertApproxEqRel(troveManager.collateral_balance(), _expectedCollateralAfterRedemption, 5e15, "E50"); // 0.5%
        assertEq(troveManager.zombie_trove_id(), _troveId, "E51");

        // Check exchange is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E52");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E53");

        // Check exchange route is empty
        assertEq(borrowToken.balanceOf(address(exchangeRoute)), 0, "E54");
        assertEq(collateralToken.balanceOf(address(exchangeRoute)), 0, "E55");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip some time, check we earn interest
    // 4. withdraw everything (+ profit) using a new exchange route
    function test_lend_withdrawUsingNewExchangeRoute(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT(), maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a trove
        mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Skip some time, calculate expected interest
        uint256 _daysToSkip = 90 days;

        // Earn Interest
        skip(_daysToSkip);

        // Report profit
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = lender.report();

        // Check return Values
        assertGt(_profit, 0, "E1");
        assertEq(_loss, 0, "E2");

        uint256 _balanceBefore = borrowToken.balanceOf(userLender);

        vm.prank(userLender);
        lender.setExchangeRouteIndex(2);

        // Check withdraw context and exchange route index
        ILender.WithdrawContext memory _withdrawContext = lender.withdrawContext();
        assertEq(_withdrawContext.routeIndex, 0, "E3");
        assertEq(_withdrawContext.receiver, address(0), "E4");
        assertEq(lender.exchangeRouteIndices(userLender), 2, "E5");

        vm.expectRevert("!route");
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // Add new exchange route
        vm.prank(deployer);
        exchangeHandler.add_route(address(exchangeRoute));

        // Withdraw all funds
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // profit > slippage
        assertGt(borrowToken.balanceOf(userLender), _balanceBefore + _amount, "E3");

        // Check withdraw context and exchange route index
        _withdrawContext = lender.withdrawContext();
        assertEq(_withdrawContext.routeIndex, 0, "E3");
        assertEq(_withdrawContext.receiver, address(0), "E4");
        assertEq(lender.exchangeRouteIndices(userLender), 2, "E5");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. skip some time, check we earn interest
    // 4. withdraw using dutch route (non-atomic swap via auction)
    // 5. take the auction
    // 6. verify lender contract received borrow tokens
    function test_lend_withdrawUsingDutchRoute(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.MIN_DEBT() * 10, maxFuzzAmount);

        // Bump up interest rate so that's it's profitible to lend
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        assertEq(lender.totalAssets(), _amount, "E0");

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded = _amount * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _upfrontFee = troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _expectedDebt = _amount + _upfrontFee;

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Check trove info
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _expectedDebt, "E1");
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.active), "E2");

        // Skip some time
        uint256 _daysToSkip = 90 days;
        skip(_daysToSkip);

        // Report profit
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = lender.report();

        // Check return Values
        assertGt(_profit, 0, "E3");
        assertEq(_loss, 0, "E4");

        // Accept ownership of dutch route
        vm.prank(management);
        dutchExchangeRoute.accept_ownership();

        // Set lender to use dutch route (index 1)
        vm.prank(userLender);
        lender.setExchangeRouteIndex(1);

        // Check exchange route index
        assertEq(lender.exchangeRouteIndices(userLender), 1, "E5");

        uint256 _lenderContractBalanceBefore = borrowToken.balanceOf(address(lender));

        // Withdraw all funds - this will kick an auction instead of atomic swap
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // Lender contract should NOT have received borrow tokens yet (auction not taken)
        assertEq(borrowToken.balanceOf(address(lender)), _lenderContractBalanceBefore, "E6");

        // Check an auction was created
        address _auction = dutchExchangeRoute.auctions(0);
        assertTrue(_auction != address(0), "E7");

        // Auction should be active
        assertTrue(IAuction(_auction).isActive(address(collateralToken)), "E8");

        // Check collateral is in auction
        uint256 _auctionAvailable = IAuction(_auction).available(address(collateralToken));
        assertGt(_auctionAvailable, 0, "E9");

        // Check dutch route has no collateral left
        assertEq(collateralToken.balanceOf(address(dutchExchangeRoute)), 0, "E10");

        // Take the auction
        uint256 _amountNeeded = IAuction(_auction).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction, _amountNeeded);
        IAuction(_auction).take(address(collateralToken));
        vm.stopPrank();

        // Auction should be empty now
        assertEq(IAuction(_auction).available(address(collateralToken)), 0, "E11");
        assertFalse(IAuction(_auction).isActive(address(collateralToken)), "E12");

        // Lender contract should have received the borrow tokens (not userLender directly)
        assertEq(borrowToken.balanceOf(address(lender)), _lenderContractBalanceBefore + _amountNeeded, "E13");

        // Check trove status
        _trove = troveManager.troves(_troveId);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.zombie), "E14");

        // Check exchange handler is empty
        assertEq(borrowToken.balanceOf(address(exchangeHandler)), 0, "E15");
        assertEq(collateralToken.balanceOf(address(exchangeHandler)), 0, "E16");

        // Check dutch route is empty
        assertEq(borrowToken.balanceOf(address(dutchExchangeRoute)), 0, "E17");
        assertEq(collateralToken.balanceOf(address(dutchExchangeRoute)), 0, "E18");
    }

    // Test that dutch route creates multiple auctions for concurrent redemptions
    function test_lend_withdrawUsingDutchRoute_multipleAuctions(
        uint256 _amount
    ) public {
        // uint256 _amount = troveManager.MIN_DEBT() * 10;
        _amount = bound(_amount, troveManager.MIN_DEBT() * 10, maxFuzzAmount);

        // Bump up interest rate
        DEFAULT_ANNUAL_INTEREST_RATE = DEFAULT_ANNUAL_INTEREST_RATE * 5; // 5%

        // Lend from two lenders
        mintAndDepositIntoLender(userLender, _amount);
        mintAndDepositIntoLender(anotherUserBorrower, _amount);

        // Calculate how much collateral is needed
        uint256 _collateralNeeded = _amount * 2 * DEFAULT_TARGET_COLLATERAL_RATIO / priceOracle.price();

        // Open a single trove with enough debt for both lenders
        mintAndOpenTrove(userBorrower, _collateralNeeded, _amount * 2, DEFAULT_ANNUAL_INTEREST_RATE);

        // Accept ownership of dutch route
        vm.prank(management);
        dutchExchangeRoute.accept_ownership();

        // Both lenders set to use dutch route (index 1)
        vm.prank(userLender);
        lender.setExchangeRouteIndex(1);
        vm.prank(anotherUserBorrower);
        lender.setExchangeRouteIndex(1);

        uint256 _lenderContractBalanceBefore = borrowToken.balanceOf(address(lender));

        // First lender withdraws - creates auction 0
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        address _auction0 = dutchExchangeRoute.auctions(0);
        assertTrue(IAuction(_auction0).isActive(address(collateralToken)), "E0");

        // Second lender withdraws while first auction is active - creates auction 1
        vm.prank(anotherUserBorrower);
        lender.redeem(_amount, anotherUserBorrower, anotherUserBorrower);

        address _auction1 = dutchExchangeRoute.auctions(1);
        assertTrue(IAuction(_auction1).isActive(address(collateralToken)), "E1");
        assertNotEq(_auction0, _auction1, "E2");

        // Take both auctions
        uint256 _amountNeeded0 = IAuction(_auction0).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded0);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction0, _amountNeeded0);
        IAuction(_auction0).take(address(collateralToken));
        vm.stopPrank();

        uint256 _amountNeeded1 = IAuction(_auction1).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded1);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction1, _amountNeeded1);
        IAuction(_auction1).take(address(collateralToken));
        vm.stopPrank();

        // Lender contract should have received both auction proceeds
        assertEq(borrowToken.balanceOf(address(lender)), _lenderContractBalanceBefore + _amountNeeded0 + _amountNeeded1, "E3");

        // Both auctions should be empty
        assertFalse(IAuction(_auction0).isActive(address(collateralToken)), "E4");
        assertFalse(IAuction(_auction1).isActive(address(collateralToken)), "E5");
    }

    function test_setDepositLimit(
        uint256 _depositLimit
    ) public {
        vm.prank(management);
        lender.setDepositLimit(_depositLimit);

        assertEq(lender.depositLimit(), _depositLimit, "E0");
    }

    function test_setDepositLimit_wrongCaller(
        uint256 _depositLimit,
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        lender.setDepositLimit(_depositLimit);
    }

}
