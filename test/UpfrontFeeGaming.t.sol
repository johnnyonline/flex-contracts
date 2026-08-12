// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract UpfrontFeeGamingTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // Compare the upfront fee to reach a 5% rate two ways: direct open vs open-at-min then
    // immediately adjust up. The gamed path only saves when the position dominates the market;
    // once the market has real depth it costs more, since it pays two average-based fees
    function test_upfrontFeeGaming(
        uint256 _existingDebt
    ) public {
        uint256 _amount = 1_000_000 * BORROW_TOKEN_PRECISION;
        uint256 _minRate = troveManager.min_annual_interest_rate();
        uint256 _targetRate = 5 * troveManager.one_pct(); // 5%

        mintAndDepositIntoLender(userLender, (_existingDebt + _amount) * 3);

        // Seed the market with existing debt at the min rate, if any
        if (_existingDebt > 0) {
            uint256 _seedCollateral =
                (_existingDebt * 200 * troveManager.one_pct() / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
            _mintAndOpenTrove(address(0xBEEF), _seedCollateral, _existingDebt, _minRate);
        }

        uint256 _collateral = (_amount * 200 * troveManager.one_pct() / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Path A: direct open at the target rate
        uint256 _feeDirect = troveManager.get_upfront_fee(_amount, _targetRate, false);

        // Path B: open at the min rate, then adjust to the target rate in the same block
        uint256 _troveId = _mintAndOpenTrove(userBorrower, _collateral, _amount, _minRate);
        uint256 _feeGamed =
            (troveManager.troves(_troveId).debt - _amount) + troveManager.get_upfront_fee(troveManager.troves(_troveId).debt, _targetRate, true);

        console2.log("existing system debt:      ", _existingDebt / BORROW_TOKEN_PRECISION);
        console2.log("  direct 5% open fee:      ", _feeDirect);
        console2.log("  gamed (open+adjust) fee: ", _feeGamed);
    }

    function test_upfrontFeeGaming_thinMarket() public {
        test_upfrontFeeGaming(0);
    }

    function test_upfrontFeeGaming_shallowMarket() public {
        test_upfrontFeeGaming(1_000_000 * BORROW_TOKEN_PRECISION);
    }

    // In a deep market the gaming backfires: the average barely moves either way, so the two
    // average-based fees of the gamed path cost more than the single direct-open fee
    function test_upfrontFeeGaming_deepMarketBackfires() public {
        uint256 _existingDebt = 50_000_000 * BORROW_TOKEN_PRECISION;
        uint256 _amount = 1_000_000 * BORROW_TOKEN_PRECISION;
        uint256 _minRate = troveManager.min_annual_interest_rate();
        uint256 _targetRate = 5 * troveManager.one_pct();

        mintAndDepositIntoLender(userLender, (_existingDebt + _amount) * 3);

        uint256 _seedCollateral =
            (_existingDebt * 200 * troveManager.one_pct() / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        _mintAndOpenTrove(address(0xBEEF), _seedCollateral, _existingDebt, _minRate);

        uint256 _collateral = (_amount * 200 * troveManager.one_pct() / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        uint256 _feeDirect = troveManager.get_upfront_fee(_amount, _targetRate, false);
        uint256 _troveId = _mintAndOpenTrove(userBorrower, _collateral, _amount, _minRate);
        uint256 _feeGamed =
            (troveManager.troves(_troveId).debt - _amount) + troveManager.get_upfront_fee(troveManager.troves(_troveId).debt, _targetRate, true);

        assertGe(_feeGamed, _feeDirect, "E0");
    }

}
