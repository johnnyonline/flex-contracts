// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

/// @title Lagging Oracle Value Extraction POC
/// @notice Verifies the fix for stale oracle value extraction: surplus goes to Lender, not redeemer
/// @dev The original vulnerability: when a borrower triggers a redemption of another borrower's collateral,
///      the auction proceeds (including any surplus above the debt) would go back to the redeemer.
///      If the oracle price is lower than the market price, the redeemer could profit from the difference.
///
/// The attempted attack flow:
/// 1. Victim has a trove with low interest rate
/// 2. Attacker opens trove with high interest rate but lender doesn't have enough liquidity
/// 3. This triggers redemption of victim's collateral (lower interest rate = redeemable)
/// 4. Auction kicks with attacker as the receiver of proceeds
/// 5. Attacker takes the auction - they pay borrow tokens, get collateral
/// 6. Attacker sells collateral at market price (higher than oracle price)
///
/// The fix: auction.receiver only gets up to `maximum_amount` (the debt owed). Any surplus goes to Lender.
/// This ensures the attacker cannot extract value from oracle lag - they only get what was owed to them according to the oracle.
contract LaggingOracleValueExtractionPOC is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_laggingOracleValueExtraction(
        uint256 _amount,
        uint256 _marketPremiumBps
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Max market premium must be less than starting price buffer, otherwise attacker can still profit
        // STARTING_PRICE_BUFFER_PERCENTAGE is 1e18 + buffer%, e.g. 1.15e18 for 15%
        uint256 _startingBufferBps = (dutchDesk.redemption_starting_price_buffer_percentage() - WAD) / 1e14;
        _marketPremiumBps = bound(_marketPremiumBps, 10, _startingBufferBps - 1);

        // Lend liquidity
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate collateral needed
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Victim opens trove at low rate
        mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Calculate victim's debt
        uint256 _victimDebt = _amount + troveManager.get_upfront_fee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Attacker setup
        uint256 _attackerBorrowAmount = _victimDebt;
        uint256 _attackerCollateral =
            (_attackerBorrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Attacker opens trove, triggering redemption
        uint256 _attackerTroveId = mintAndOpenTrove(userBorrower, _attackerCollateral, _attackerBorrowAmount, DEFAULT_ANNUAL_INTEREST_RATE * 2);

        // Verify auction created with attacker as receiver
        assertEq(auction.auctions(0).receiver, userBorrower, "E0");

        uint256 _auctionCollateral = auction.get_available_amount(0);
        uint256 _maximumAmount = auction.auctions(0).maximumAmount;

        // Track lender balance before auction take
        uint256 _lenderBalanceBefore = borrowToken.balanceOf(address(lender));

        // Attacker takes auction - brings borrow tokens from home
        uint256 _neededAmount = auction.get_needed_amount(0, _auctionCollateral, block.timestamp);
        uint256 _borrowFromHome = _neededAmount;
        airdrop(address(borrowToken), userBorrower, _neededAmount);

        vm.startPrank(userBorrower);
        borrowToken.approve(address(auction), _neededAmount);
        auction.take(0, _auctionCollateral, userBorrower, "");
        vm.stopPrank();

        // Verify surplus went to lender (not to attacker)
        uint256 _lenderBalanceAfter = borrowToken.balanceOf(address(lender));
        uint256 _surplusToLender = _lenderBalanceAfter - _lenderBalanceBefore;
        if (_neededAmount > _maximumAmount) assertEq(_surplusToLender, _neededAmount - _maximumAmount, "E1");

        // Attacker now has auction collateral - sells it at market price
        // Market price = oracle price + premium
        uint256 _auctionCollateralMarketValue =
            _auctionCollateral * priceOracle.get_price() / ORACLE_PRICE_SCALE * (10000 + _marketPremiumBps) / 10000;

        // Simulate selling collateral at market price
        deal(address(collateralToken), userBorrower, collateralToken.balanceOf(userBorrower) - _auctionCollateral);
        airdrop(address(borrowToken), userBorrower, _auctionCollateralMarketValue, true); // add to balance

        // Attacker closes their trove using proceeds from selling auction collateral
        uint256 _attackerDebt = troveManager.get_trove_debt_after_interest(_attackerTroveId);

        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), _attackerDebt);
        troveManager.close_trove(_attackerTroveId);
        vm.stopPrank();

        // Calculate what attacker ends up with
        uint256 _finalCollateralBalance = collateralToken.balanceOf(userBorrower);
        uint256 _finalBorrowBalance = borrowToken.balanceOf(userBorrower);

        // Attacker brought from home:
        // - _attackerCollateral (collateral for opening trove)
        // - _borrowFromHome (borrow tokens for taking auction)
        //
        // Attacker ends up with:
        // - _finalCollateralBalance (should be _attackerCollateral from closing trove)
        // - _finalBorrowBalance

        // FIX VERIFICATION: Attacker should NOT profit from the operation
        // Even though they sold collateral at a higher market price, the surplus went to Lender
        assertEq(_finalCollateralBalance, _attackerCollateral, "E2");
        assertGe(_borrowFromHome, _finalBorrowBalance, "E3");
    }

}
