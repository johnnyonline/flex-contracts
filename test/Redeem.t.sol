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
