// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract TroveManagerTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setup() public {
        assertEq(troveManager.lender(), address(lender), "E0");
        assertEq(troveManager.dutch_desk(), address(dutchDesk), "E1");
        assertEq(troveManager.price_oracle(), address(priceOracle), "E2");
        assertEq(troveManager.sorted_troves(), address(sortedTroves), "E3");
        assertEq(troveManager.borrow_token(), address(borrowToken), "E4");
        assertEq(troveManager.collateral_token(), address(collateralToken), "E5");
        assertEq(troveManager.one_pct(), BORROW_TOKEN_PRECISION / 100, "E6");
        assertEq(troveManager.borrow_token_precision(), BORROW_TOKEN_PRECISION, "E7");
        assertEq(troveManager.min_debt(), minimumDebt * BORROW_TOKEN_PRECISION, "E8");
        assertEq(troveManager.minimum_collateral_ratio(), minimumCollateralRatio * BORROW_TOKEN_PRECISION / 100, "E9");
        assertEq(troveManager.max_penalty_collateral_ratio(), maxPenaltyCollateralRatio * BORROW_TOKEN_PRECISION / 100, "E10");
        assertEq(troveManager.min_liquidation_fee(), minLiquidationFee * BORROW_TOKEN_PRECISION / 100 / 100, "E11");
        assertEq(troveManager.max_liquidation_fee(), maxLiquidationFee * BORROW_TOKEN_PRECISION / 100 / 100, "E12");
        assertEq(troveManager.upfront_interest_period(), upfrontInterestPeriod, "E13");
        assertEq(troveManager.interest_rate_adj_cooldown(), interestRateAdjCooldown, "E14");
        assertEq(troveManager.min_annual_interest_rate(), BORROW_TOKEN_PRECISION / 100 / 2, "E15"); // 0.5%
        assertEq(troveManager.max_annual_interest_rate(), 250 * BORROW_TOKEN_PRECISION / 100, "E16"); // 250%
        assertEq(troveManager.zombie_trove_id(), 0, "E17");
        assertEq(troveManager.total_debt(), 0, "E18");
        assertEq(troveManager.total_weighted_debt(), 0, "E19");
        assertEq(troveManager.last_debt_update_time(), 0, "E20");
        assertEq(troveManager.collateral_balance(), 0, "E21");
    }

    function test_initialize_revertsIfAlreadyInitialized() public {
        vm.expectRevert("initialized");
        troveManager.initialize(
            ITroveManager.InitializeParams({
                lender: address(lender),
                dutch_desk: address(dutchDesk),
                price_oracle: address(priceOracle),
                sorted_troves: address(sortedTroves),
                borrow_token: address(borrowToken),
                collateral_token: address(collateralToken),
                minimum_debt: minimumDebt,
                minimum_collateral_ratio: minimumCollateralRatio,
                max_penalty_collateral_ratio: maxPenaltyCollateralRatio,
                min_liquidation_fee: minLiquidationFee,
                max_liquidation_fee: maxLiquidationFee,
                upfront_interest_period: upfrontInterestPeriod,
                interest_rate_adj_cooldown: interestRateAdjCooldown
            })
        );
    }

}
