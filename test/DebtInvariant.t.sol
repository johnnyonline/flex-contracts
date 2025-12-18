// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract DebtInvariantTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    // Fuzz test to find edge cases where sum(trove debts) > total_debt due to floor division
    // Liquity uses ceiling division for aggregate interest to ensure system debt >= sum(trove debts)
    // We _used_ floor division which could cause sum(trove debts) > total_debt
    //
    //
    // Old calculation:
    // ```
    // pending_agg_interest: uint256 = (
    //     (self.total_weighted_debt * (block.timestamp - self.last_debt_update_time)) // (_ONE_YEAR * _BORROW_TOKEN_PRECISION)
    // )
    // ```
    // -------------
    // New calculation:
    // ```
    // pending_agg_interest: uint256 = math._ceil_div(
    //     self.total_weighted_debt * (block.timestamp - self.last_debt_update_time),
    //     _ONE_YEAR * _BORROW_TOKEN_PRECISION
    // )
    // ```
    function test_interestAccrual_roundingMismatch(
        uint256[20] memory _amounts,
        uint256[20] memory _rates,
        uint256 _timePerSync,
        uint256 _numSyncs
    ) public {
        uint256 _minRate = troveManager.MIN_ANNUAL_INTEREST_RATE();
        uint256 _maxRate = troveManager.MAX_ANNUAL_INTEREST_RATE();
        uint256 _minDebt = troveManager.MIN_DEBT();

        // Bound time to small intervals to maximize rounding operations
        _timePerSync = bound(_timePerSync, 1, 365 days);
        _numSyncs = bound(_numSyncs, 1, 100);

        // Fund lender
        mintAndDepositIntoLender(userLender, maxFuzzAmount * 20);

        uint256[] memory _troveIds = new uint256[](20);

        // Open 20 troves with fuzzed amounts and rates
        for (uint256 i = 0; i < 20; i++) {
            _amounts[i] = bound(_amounts[i], _minDebt, maxFuzzAmount);
            _rates[i] = bound(_rates[i], _minRate, _maxRate);

            uint256 _collateralNeeded =
                (_amounts[i] * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.price();

            address _user = address(uint160(i + 100));
            _troveIds[i] = mintAndOpenTrove(_user, _collateralNeeded, _amounts[i], _rates[i]);
        }

        // Perform multiple time skips and syncs to accumulate rounding errors
        for (uint256 j = 0; j < _numSyncs; j++) {
            skip(_timePerSync);
            troveManager.sync_total_debt();
        }

        // Get total debt from contract
        uint256 _totalDebtFromContract = troveManager.total_debt();

        // Calculate sum of individual trove debts
        uint256 _sumOfTroveDebts = 0;
        for (uint256 i = 0; i < 20; i++) {
            uint256 _troveDebt = troveManager.get_trove_debt_after_interest(_troveIds[i]);
            _sumOfTroveDebts += _troveDebt;
        }

        // This assertion should fail if sum(trove debts) > total_debt
        // which would mean the system is insolvent
        assertGe(_totalDebtFromContract, _sumOfTroveDebts, "CRITICAL: sum(trove debts) > total_debt");
    }

}
