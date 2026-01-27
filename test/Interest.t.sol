// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract InterestTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // Test interest accrual on single trove over time
    function test_interestAccrual_singleTrove(
        uint256 _amount,
        uint256 _rate,
        uint256 _timeElapsed
    ) public {
        uint256 _minRate = troveManager.min_annual_interest_rate();
        uint256 _maxRate = troveManager.max_annual_interest_rate();

        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);
        _rate = bound(_rate, _minRate, _maxRate);
        _timeElapsed = bound(_timeElapsed, 1 days, 730 days);

        // Lend some from lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate how much collateral is needed for the borrow amount
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Calculate expected debt (borrow amount + upfront fee)
        uint256 _upfrontFee = troveManager.get_upfront_fee(_amount, _rate);
        uint256 _initialDebt = _amount + _upfrontFee;

        // Open a trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, _rate);

        // Verify initial state
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        assertEq(_trove.debt, _initialDebt, "E0");
        assertEq(troveManager.total_debt(), _initialDebt, "E1");
        assertEq(troveManager.total_weighted_debt(), _initialDebt * _rate, "E2");

        // Move time forward
        skip(_timeElapsed);

        // Calculate expected interest
        // interest = principal * rate * time / (365 days * BORROW_TOKEN_PRECISION)
        uint256 _expectedInterest = _initialDebt * _rate * _timeElapsed / (365 days * BORROW_TOKEN_PRECISION);

        // Sync total debt to accrue interest
        uint256 _newTotalDebt = troveManager.sync_total_debt();

        // Verify total debt increased by expected interest
        assertApproxEqAbs(_newTotalDebt, _initialDebt + _expectedInterest, 2, "E3");

        // Close trove to verify actual debt owed
        uint256 _debtToRepay = _initialDebt + _expectedInterest;
        airdrop(address(borrowToken), userBorrower, _debtToRepay);
        vm.startPrank(userBorrower);
        borrowToken.approve(address(troveManager), _debtToRepay);
        troveManager.close_trove(_troveId);
        vm.stopPrank();

        // Verify trove is closed and debt is cleared
        _trove = troveManager.troves(_troveId);
        assertEq(uint256(_trove.status), uint256(ITroveManager.Status.closed), "E4");
        assertApproxEqAbs(troveManager.total_debt(), 0, 2, "E5");
    }

    // Test interest accrual on multiple troves with different rates
    function test_interestAccrual_multipleTroves(
        uint256[3] memory _amounts,
        uint256[3] memory _rates,
        uint256 _timeElapsed
    ) public {
        _timeElapsed = bound(_timeElapsed, 1 days, 730 days);

        uint256 _totalInitialDebt = 0;
        uint256 _totalWeightedDebt = 0;
        uint256[] memory _initialDebts = new uint256[](3);
        uint256[] memory _boundedRates = new uint256[](3);

        // Fund lender with enough for all troves
        mintAndDepositIntoLender(userLender, maxFuzzAmount * 3);

        // Open 3 troves with different amounts and rates
        for (uint256 i = 0; i < 3; i++) {
            _amounts[i] = bound(_amounts[i], troveManager.min_debt(), maxFuzzAmount);
            _boundedRates[i] = bound(_rates[i], troveManager.min_annual_interest_rate(), troveManager.max_annual_interest_rate());

            uint256 _collateralNeeded =
                (_amounts[i] * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
            uint256 _upfrontFee = troveManager.get_upfront_fee(_amounts[i], _boundedRates[i]);
            _initialDebts[i] = _amounts[i] + _upfrontFee;

            address _user = address(uint160(i + 1));
            mintAndOpenTrove(_user, _collateralNeeded, _amounts[i], _boundedRates[i]);

            _totalInitialDebt += _initialDebts[i];
            _totalWeightedDebt += _initialDebts[i] * _boundedRates[i];
        }

        // Verify initial state
        assertEq(troveManager.total_debt(), _totalInitialDebt, "E0");
        assertEq(troveManager.total_weighted_debt(), _totalWeightedDebt, "E1");

        // Move time forward
        skip(_timeElapsed);

        // Calculate expected interest using weighted average rate
        // interest = total_weighted_debt * time / (365 days * BORROW_TOKEN_PRECISION)
        uint256 _expectedInterest = _totalWeightedDebt * _timeElapsed / (365 days * BORROW_TOKEN_PRECISION);

        // Sync total debt to accrue interest
        uint256 _newTotalDebt = troveManager.sync_total_debt();

        // Verify total debt increased by expected interest
        assertApproxEqAbs(_newTotalDebt, _totalInitialDebt + _expectedInterest, 2, "E2");
    }

    // Test interest accrual after rate adjustment
    function test_interestAccrual_afterRateAdjustment(
        uint256 _amount,
        uint256 _initialRate,
        uint256 _newRate,
        uint256 _timeElapsed1,
        uint256 _timeElapsed2
    ) public {
        uint256 _minRate = troveManager.min_annual_interest_rate();
        uint256 _maxRate = troveManager.max_annual_interest_rate();

        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);
        _initialRate = bound(_initialRate, _minRate, _maxRate);
        _newRate = bound(_newRate, _minRate, _maxRate);
        _timeElapsed1 = bound(_timeElapsed1, troveManager.interest_rate_adj_cooldown(), 365 days);
        _timeElapsed2 = bound(_timeElapsed2, 1 days, 365 days);

        // Make sure new rate is different from initial rate
        if (_newRate == _initialRate) _newRate = _initialRate == _maxRate ? _minRate : _initialRate + 1;

        // Fund lender
        mintAndDepositIntoLender(userLender, _amount);

        // Calculate collateral and initial debt
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _upfrontFee1 = troveManager.get_upfront_fee(_amount, _initialRate);
        uint256 _initialDebt = _amount + _upfrontFee1;

        // Open trove
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, _initialRate);

        // Move time forward (first period)
        skip(_timeElapsed1);

        // Calculate interest for first period
        uint256 _interest1 = _initialDebt * _initialRate * _timeElapsed1 / (365 days * BORROW_TOKEN_PRECISION);

        // Adjust rate (no upfront fee since we waited past INTEREST_RATE_ADJ_COOLDOWN)
        vm.prank(userBorrower);
        troveManager.adjust_interest_rate(_troveId, _newRate, 0, 0, type(uint256).max);

        // Get debt after rate adjustment (includes interest from first period, no upfront fee)
        uint256 _debtAfterAdjustment = _initialDebt + _interest1;

        // Verify weighted debt updated
        assertEq(troveManager.total_weighted_debt(), _debtAfterAdjustment * _newRate, "E0");

        // Move time forward (second period)
        skip(_timeElapsed2);

        // Calculate interest for second period
        uint256 _interest2 = _debtAfterAdjustment * _newRate * _timeElapsed2 / (365 days * BORROW_TOKEN_PRECISION);

        // Sync total debt
        uint256 _newTotalDebt = troveManager.sync_total_debt();

        // Verify total debt
        assertApproxEqAbs(_newTotalDebt, _debtAfterAdjustment + _interest2, 2, "E2");
    }

}
