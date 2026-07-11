// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IPriceOracleNotScaled} from "./interfaces/IPriceOracleNotScaled.sol";
import {IPriceOracleScaled} from "./interfaces/IPriceOracleScaled.sol";

import "./Base.sol";

contract ProtocolFeesTests is Base {

    event ClaimProtocolFees(address indexed recipient, uint256 amount);
    event BadDebt(uint256 indexed trove_id, uint256 loss, uint256 loss_absorbed_by_fees);

    function setUp() public override {
        Base.setUp();
    }

    /// @dev Open a trove at the target collateral ratio and return (troveId, fee)
    function _openTroveWithFee(
        uint256 _amount,
        uint256 _rate
    ) internal returns (uint256, uint256) {
        uint256 _collateral = (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _feesBefore = troveManager.unclaimed_protocol_fees();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateral, _amount, _rate);
        return (_troveId, troveManager.unclaimed_protocol_fees() - _feesBefore);
    }

    /// @dev Drop the oracle price so the trove sits at the given collateral ratio (in percent)
    function _dropPriceToCollateralRatio(
        uint256 _troveId,
        uint256 _collateralRatio
    ) internal {
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        uint256 _price = _collateralRatio * troveManager.one_pct() * _trove.debt * ORACLE_PRICE_SCALE / (_trove.collateral * BORROW_TOKEN_PRECISION);
        uint256 _price18 = _price * COLLATERAL_TOKEN_PRECISION * WAD / (ORACLE_PRICE_SCALE * BORROW_TOKEN_PRECISION);
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_price));
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_price18));
    }

    // The upfront fee accrues to the protocol on open
    function test_accrue_onOpenTrove(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), troveManager.min_debt() * 100);
        mintAndDepositIntoLender(userLender, _amount);
        assertEq(troveManager.unclaimed_protocol_fees(), 0, "E0");

        (uint256 _troveId, uint256 _fee) = _openTroveWithFee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // The fee is the difference between the trove's debt and the borrowed amount
        assertGt(_fee, 0, "E1");
        assertEq(_fee, troveManager.troves(_troveId).debt - _amount, "E2");
    }

    // The upfront fee accrues to the protocol on borrow
    function test_accrue_onBorrow(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), troveManager.min_debt() * 100);
        mintAndDepositIntoLender(userLender, _amount * 2);

        // Open with collateral sized for the future borrow too
        uint256 _collateral = (_amount * 2 * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateral, _amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _debtBefore = troveManager.troves(_troveId).debt;
        uint256 _openFee = troveManager.unclaimed_protocol_fees();

        // Borrow more
        vm.prank(userBorrower);
        troveManager.borrow(_troveId, _amount / 2, type(uint256).max, 0, 0);

        // The fee is the difference between the debt delta and the borrowed amount
        uint256 _borrowFee = troveManager.troves(_troveId).debt - _debtBefore - _amount / 2;
        assertGt(_borrowFee, 0, "E0");
        assertEq(troveManager.unclaimed_protocol_fees(), _openFee + _borrowFee, "E1");
    }

    // The upfront fee accrues to the protocol on premature rate adjustments only
    function test_accrue_onAdjustInterestRate(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), troveManager.min_debt() * 100);
        mintAndDepositIntoLender(userLender, _amount);

        (uint256 _troveId, uint256 _openFee) = _openTroveWithFee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        uint256 _debtBefore = troveManager.troves(_troveId).debt;

        // Premature adjustment (within the cooldown) charges a fee
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, DEFAULT_ANNUAL_INTEREST_RATE * 2, 0, 0, type(uint256).max);
        uint256 _adjustFee = troveManager.troves(_troveId).debt - _debtBefore;
        assertGt(_adjustFee, 0, "E0");
        assertEq(troveManager.unclaimed_protocol_fees(), _openFee + _adjustFee, "E1");

        // After the cooldown, adjusting is free
        skip(interestRateAdjCooldown);
        uint256 _feesBefore = troveManager.unclaimed_protocol_fees();
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, DEFAULT_ANNUAL_INTEREST_RATE * 3, 0, 0, type(uint256).max);
        assertEq(troveManager.unclaimed_protocol_fees(), _feesBefore, "E2");
    }

    // The fee recipient claims from the Lender's idle liquidity
    function test_claimProtocolFees_fromIdle(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), troveManager.min_debt() * 100);
        mintAndDepositIntoLender(userLender, _amount * 2);

        (, uint256 _fee) = _openTroveWithFee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Claim
        uint256 _balanceBefore = borrowToken.balanceOf(address(daddy));
        vm.expectEmit(true, false, false, true, address(troveManager));
        emit ClaimProtocolFees(address(daddy), _fee);
        vm.prank(address(daddy));
        troveManager.claim_protocol_fees(_fee, 0);

        // The recipient got the fee in borrow tokens
        assertEq(borrowToken.balanceOf(address(daddy)), _balanceBefore + _fee, "E0");
        assertEq(troveManager.unclaimed_protocol_fees(), 0, "E1");

        // The claim is PPS neutral: a follow-up report shows no profit and no loss
        (uint256 _profit, uint256 _loss) = IKeeper(lenderFactory.KEEPER()).report(address(lender));
        assertEq(_profit, 0, "E2");
        assertEq(_loss, 0, "E3");
    }

    // With no idle liquidity, the claim redeems and kicks an auction with the recipient as receiver
    function test_claimProtocolFees_redemption(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, troveManager.min_debt() * 100);
        mintAndDepositIntoLender(userLender, _amount);

        // The open consumes all the idle liquidity
        (uint256 _troveId, uint256 _fee) = _openTroveWithFee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        assertEq(borrowToken.balanceOf(address(lender)), 0, "E0");

        uint256 _debtBefore = troveManager.troves(_troveId).debt;
        uint256 _expectedRedeemedColl = _fee * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _nonceBefore = IDutchDesk(troveManager.dutch_desk()).nonce();

        // Claim
        vm.prank(address(daddy));
        troveManager.claim_protocol_fees(0, _expectedRedeemedColl);

        // The claim kicked an auction with the recipient as the receiver of the proceeds
        assertEq(IDutchDesk(troveManager.dutch_desk()).nonce(), _nonceBefore + 1, "E1");
        assertEq(auction.auctions(_nonceBefore).receiver, address(daddy), "E2");
        assertEq(auction.get_available_amount(_nonceBefore), _expectedRedeemedColl, "E3");

        // The fees were claimed by redeeming the borrower's trove
        assertEq(troveManager.unclaimed_protocol_fees(), 0, "E4");
        assertEq(troveManager.troves(_troveId).debt, _debtBefore - _fee, "E5");
    }

    function test_claimProtocolFees_notRecipient_reverts(
        address _caller
    ) public {
        vm.assume(_caller != address(daddy) && _caller != address(0));
        vm.prank(_caller);
        vm.expectRevert("!recipient");
        troveManager.claim_protocol_fees(0, 0);
    }

    function test_claimProtocolFees_noFees_reverts() public {
        vm.prank(address(daddy));
        vm.expectRevert("!unclaimed");
        troveManager.claim_protocol_fees(0, 0);
    }

    // The upfront fee never shows up as lender profit
    function test_report_excludesFees(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), troveManager.min_debt() * 100);
        mintAndDepositIntoLender(userLender, _amount * 2);

        (uint256 _troveId,) = _openTroveWithFee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Right after the open, the fee is accrued but excluded: no profit
        (uint256 _profit, uint256 _loss) = IKeeper(lenderFactory.KEEPER()).report(address(lender));
        assertEq(_profit, 0, "E0");
        assertEq(_loss, 0, "E1");

        // After some time, the profit is the interest only
        uint256 _daysToSkip = 90 days;
        uint256 _debt = troveManager.troves(_troveId).debt;
        uint256 _expectedInterest = _debt * DEFAULT_ANNUAL_INTEREST_RATE * _daysToSkip / 365 days / BORROW_TOKEN_PRECISION;
        skip(_daysToSkip);
        (_profit, _loss) = IKeeper(lenderFactory.KEEPER()).report(address(lender));
        assertApproxEqAbs(_profit, _expectedInterest, 2, "E2");
        assertEq(_loss, 0, "E3");
    }

    // A small bad debt is fully absorbed by the accrued fees: lenders see no loss and no report fires
    function test_badDebt_feesAbsorbLoss() public {
        uint256 _amount = troveManager.min_debt() * 2;
        mintAndDepositIntoLender(userLender, _amount);

        // Open at the maximum interest rate so the upfront fee is large (~4.8% of the debt)
        (uint256 _troveId, uint256 _fee) = _openTroveWithFee(_amount, troveManager.max_annual_interest_rate());

        // Drop the price so the trove is just barely underwater: the loss (~1% of the debt) < the fee
        _dropPriceToCollateralRatio(_troveId, 104);

        uint256 _ppsBefore = lender.pricePerShare();
        uint256 _lenderBalanceBefore = borrowToken.balanceOf(address(lender));

        // Liquidate
        vm.expectEmit(true, false, false, false, address(troveManager));
        emit BadDebt(_troveId, 0, 0); // only the trove id is checked
        liquidate(_troveId);

        // The loss was absorbed by the fees, exactly
        uint256 _loss = _amount + _fee - (borrowToken.balanceOf(address(lender)) - _lenderBalanceBefore);
        assertGt(_loss, 0, "E0");
        assertLt(_loss, _fee, "E1");
        assertEq(troveManager.unclaimed_protocol_fees(), _fee - _loss, "E2");

        // No atomic report fired: PPS is untouched
        assertEq(lender.pricePerShare(), _ppsBefore, "E3");

        // A follow-up report shows no loss
        (uint256 _profit, uint256 _reportedLoss) = IKeeper(lenderFactory.KEEPER()).report(address(lender));
        assertEq(_profit, 0, "E4");
        assertEq(_reportedLoss, 0, "E5");
    }

    // A large bad debt exhausts the fees and the remainder is reported to the lenders atomically
    function test_badDebt_lossExceedsFees() public {
        uint256 _amount = troveManager.min_debt() * 2;
        mintAndDepositIntoLender(userLender, _amount);

        (uint256 _troveId, uint256 _fee) = _openTroveWithFee(_amount, DEFAULT_ANNUAL_INTEREST_RATE);
        assertGt(_fee, 0, "E0");

        // Drop the price so the trove is deeply underwater: the loss far exceeds the fee
        _dropPriceToCollateralRatio(_troveId, 90);

        uint256 _ppsBefore = lender.pricePerShare();

        // Liquidate
        vm.expectEmit(true, false, false, false, address(troveManager));
        emit BadDebt(_troveId, 0, 0); // only the trove id is checked
        liquidate(_troveId);

        // The fees were exhausted and the remaining loss hit the lenders atomically
        assertEq(troveManager.unclaimed_protocol_fees(), 0, "E1");
        assertLt(lender.pricePerShare(), _ppsBefore, "E2");
    }

}
