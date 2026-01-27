// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract TroveManagerTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setup() public {
        // Contracts
        assertEq(troveManager.lender(), address(lender), "E0");
        assertEq(troveManager.dutch_desk(), address(dutchDesk), "E1");
        assertEq(troveManager.price_oracle(), address(priceOracle), "E2");
        assertEq(troveManager.sorted_troves(), address(sortedTroves), "E3");

        // Tokens
        assertEq(troveManager.borrow_token(), address(borrowToken), "E4");
        assertEq(troveManager.collateral_token(), address(collateralToken), "E5");

        // Parameters
        assertEq(troveManager.one_pct(), BORROW_TOKEN_PRECISION / 100, "E6");
        assertEq(troveManager.borrow_token_precision(), BORROW_TOKEN_PRECISION, "E7");
        assertEq(troveManager.min_debt(), 500 * BORROW_TOKEN_PRECISION, "E8");
        assertEq(troveManager.minimum_collateral_ratio(), minimumCollateralRatio * BORROW_TOKEN_PRECISION / 100, "E9");
        assertEq(troveManager.min_annual_interest_rate(), BORROW_TOKEN_PRECISION / 100 / 2, "E10"); // 0.5%
        assertEq(troveManager.max_annual_interest_rate(), 250 * BORROW_TOKEN_PRECISION / 100, "E11"); // 250%
        assertEq(troveManager.upfront_interest_period(), 7 days, "E12");
        assertEq(troveManager.interest_rate_adj_cooldown(), 7 days, "E13");

        // Accounting
        assertEq(troveManager.zombie_trove_id(), 0, "E14");
        assertEq(troveManager.total_debt(), 0, "E15");
        assertEq(troveManager.total_weighted_debt(), 0, "E16");
        assertEq(troveManager.last_debt_update_time(), 0, "E17");
        assertEq(troveManager.collateral_balance(), 0, "E18");
    }

}
