// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceOracleNotScaled} from "./interfaces/IPriceOracleNotScaled.sol";
import {IPriceOracleScaled} from "./interfaces/IPriceOracleScaled.sol";

import "./Base.sol";

contract RedeemTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_redeem_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != address(lender));

        vm.expectRevert("!lender");
        troveManager.redeem(0, address(0));
    }

    // A borrow-path redemption skips the borrower's own Troves even when someone else (e.g. the
    // Leverage Zapper) opens on their behalf
    function test_redeem_skipsOwnTroves_openOnBehalf(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount / 2);
        mintAndDepositIntoLender(userLender, _amount * 2);

        uint256 _collateral = (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // The owner's own Trove sits at the lowest rate, so a naive walk would redeem it first
        uint256 _ownTroveId = mintAndOpenTrove(userBorrower, _collateral, _amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _otherTroveId = mintAndOpenTrove(anotherUserBorrower, _collateral, _amount, DEFAULT_ANNUAL_INTEREST_RATE * 2);
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        uint256 _ownDebtBefore = troveManager.troves(_ownTroveId).debt;
        uint256 _otherDebtBefore = troveManager.troves(_otherTroveId).debt;

        // The operator opens a Trove on the owner's behalf at a higher rate, triggering a redemption
        uint256 _debtAmount = _amount / 2;
        airdrop(address(collateralToken), operator, _collateral);
        vm.startPrank(operator);
        collateralToken.approve(address(troveManager), _collateral);
        troveManager.open_trove(0, _collateral, _debtAmount, 0, 0, DEFAULT_ANNUAL_INTEREST_RATE * 4, type(uint256).max, 0, 0, userBorrower);
        vm.stopPrank();

        // The owner's own Trove was skipped; the other borrower's Trove was redeemed
        assertEq(troveManager.troves(_ownTroveId).debt, _ownDebtBefore, "E1");
        assertEq(troveManager.troves(_otherTroveId).debt, _otherDebtBefore - _debtAmount, "E2");
    }

    // A borrow-path redemption skips the borrowing Trove owner's other Troves even when an
    // approved operator (e.g. the Leverage Zapper) borrows on their behalf
    function test_redeem_skipsOwnTroves_borrowOnBehalf(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount / 2);
        mintAndDepositIntoLender(userLender, _amount * 3);

        uint256 _collateral = (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // The owner's own Trove sits at the lowest rate, so a naive walk would redeem it first
        uint256 _ownTroveId = mintAndOpenTrove(userBorrower, _collateral, _amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _otherTroveId = mintAndOpenTrove(anotherUserBorrower, _collateral, _amount, DEFAULT_ANNUAL_INTEREST_RATE * 2);

        // The owner's second Trove, with headroom to borrow more (skip a second to avoid a trove id collision)
        skip(1);
        uint256 _borrowTroveId = mintAndOpenTrove(userBorrower, _collateral * 2, _amount, DEFAULT_ANNUAL_INTEREST_RATE * 4);
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        uint256 _ownDebtBefore = troveManager.troves(_ownTroveId).debt;
        uint256 _otherDebtBefore = troveManager.get_trove_debt_after_interest(_otherTroveId);

        // The owner approves the operator, which borrows more on their behalf, triggering a redemption
        vm.prank(userBorrower);
        troveManager.approve(operator, true);
        uint256 _debtAmount = _amount / 2;
        vm.prank(operator);
        troveManager.borrow(_borrowTroveId, _debtAmount, type(uint256).max, 0, 0);

        // The owner's own Trove was skipped; the other borrower's Trove was redeemed
        assertEq(troveManager.troves(_ownTroveId).debt, _ownDebtBefore, "E1");
        assertEq(troveManager.troves(_otherTroveId).debt, _otherDebtBefore - _debtAmount, "E2");
    }

    // A redeeming lender who wants the collateral itself can simply take its own auction: as both
    // taker and kick receiver the payment nets out, so it keeps the collateral in kind and pays nothing
    function test_redeem_receiverSelfTake_receivesCollateral(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), troveManager.min_debt() * 100);

        // Lend
        mintAndDepositIntoLender(userLender, _amount);

        // Open a trove that borrows all the idle liquidity
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        uint256 _debtBefore = troveManager.troves(_troveId).debt;

        // Withdraw everything: kicks a redemption auction with the lender user as the receiver
        vm.prank(userLender);
        lender.redeem(_amount, userLender, userLender);

        // Check the auction
        uint256 _auctionId = 0;
        assertTrue(auction.is_active(_auctionId), "E1");
        assertEq(auction.auctions(_auctionId).receiver, userLender, "E2");
        uint256 _kickedCollateral = auction.get_available_amount(_auctionId);
        assertGt(_kickedCollateral, 0, "E3");

        // Skip time until the price decays to the oracle price, so the take is fully covered by the netting
        uint256 _stepDuration = auction.step_duration();
        uint256 _targetPrice = priceOracle.get_price(false);
        uint256 _currentPrice = auction.get_price(_auctionId, block.timestamp);
        uint256 _steps = 0;
        while (_currentPrice > _targetPrice && _steps < 1440) {
            _steps++;
            _currentPrice = auction.get_price(_auctionId, block.timestamp + _steps * _stepDuration);
        }
        if (_steps > 0) skip(_steps * _stepDuration);

        // The receiver takes its own auction without holding or approving any borrow tokens:
        // the payment nets out against the proceeds it is owed
        assertEq(borrowToken.balanceOf(userLender), 0, "E4");
        vm.prank(userLender);
        auction.take(_auctionId, type(uint256).max, userLender, "");

        // The receiver got the redeemed collateral in kind, and no borrow tokens moved anywhere
        assertEq(collateralToken.balanceOf(userLender), _kickedCollateral, "E5");
        assertEq(borrowToken.balanceOf(userLender), 0, "E6");
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E7");

        // The auction is settled
        assertEq(auction.get_available_amount(_auctionId), 0, "E8");
        assertFalse(auction.is_active(_auctionId), "E9");

        // The borrower's trove was redeemed
        assertEq(troveManager.troves(_troveId).debt, _debtBefore - _amount, "E10");
    }

    // Redeeming an underwater trove reverts on underflow (collateral_to_redeem > trove.collateral)
    function test_redeemUnderwaterTrove_reverts() public {
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

        // Verify CR is below 100%
        uint256 _cr = (_trove.collateral * _price / ORACLE_PRICE_SCALE) * BORROW_TOKEN_PRECISION / _trove.debt;
        assertLt(_cr, BORROW_TOKEN_PRECISION, "E0");

        // Attempting to redeem the full debt reverts because collateral_to_redeem > trove.collateral
        vm.prank(address(lender));
        vm.expectRevert();
        troveManager.redeem(type(uint256).max, address(lender));
    }

}
