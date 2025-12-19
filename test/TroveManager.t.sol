// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract TroveManagerTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setup() public {
        assertEq(troveManager.LENDER(), address(lender), "E0");
        assertEq(troveManager.DUTCH_DESK(), address(dutchDesk), "E1");
        assertEq(troveManager.PRICE_ORACLE(), address(priceOracle), "E2");
        assertEq(troveManager.SORTED_TROVES(), address(sortedTroves), "E3");
        assertEq(troveManager.BORROW_TOKEN(), address(borrowToken), "E4");
        assertEq(troveManager.COLLATERAL_TOKEN(), address(collateralToken), "E5");
        assertEq(troveManager.MIN_DEBT(), 500 * BORROW_TOKEN_PRECISION, "E6");
        assertEq(troveManager.MINIMUM_COLLATERAL_RATIO(), minimumCollateralRatio * BORROW_TOKEN_PRECISION / 100, "E7");
        assertEq(troveManager.MIN_ANNUAL_INTEREST_RATE(), BORROW_TOKEN_PRECISION / 100 / 2, "E8"); // 0.5%
        assertEq(troveManager.MAX_ANNUAL_INTEREST_RATE(), 250 * BORROW_TOKEN_PRECISION / 100, "E9"); // 250%
        assertEq(troveManager.UPFRONT_INTEREST_PERIOD(), 7 days, "E10");
        assertEq(troveManager.INTEREST_RATE_ADJ_COOLDOWN(), 7 days, "E11");
        assertEq(troveManager.zombie_trove_id(), 0, "E12");
        assertEq(troveManager.total_debt(), 0, "E13");
        assertEq(troveManager.total_weighted_debt(), 0, "E14");
        assertEq(troveManager.last_debt_update_time(), 0, "E15");
        assertEq(troveManager.collateral_balance(), 0, "E16");
    }

}
