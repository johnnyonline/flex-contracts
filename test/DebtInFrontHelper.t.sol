// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IDebtInFrontHelper} from "./interfaces/IDebtInFrontHelper.sol";

import "./Base.sol";

contract DebtInFrontHelperTests is Base {

    IDebtInFrontHelper public debtInFrontHelper;

    // Interest rates for testing (based on one_pct = borrow_token_precision / 100)
    uint256 public rate1; // 5%
    uint256 public rate2; // 10%
    uint256 public rate3; // 15%
    uint256 public rate4; // 20%

    function setUp() public override {
        Base.setUp();

        // Deploy DebtInFrontHelper
        debtInFrontHelper = IDebtInFrontHelper(deployCode("debt_in_front_helper", abi.encode(address(troveManager), address(sortedTroves))));

        vm.label(address(debtInFrontHelper), "DebtInFrontHelper");

        // Set interest rates based on one_pct (borrow_token_precision / 100)
        uint256 _onePct = troveManager.one_pct();
        rate1 = 5 * _onePct; // 5%
        rate2 = 10 * _onePct; // 10%
        rate3 = 15 * _onePct; // 15%
        rate4 = 20 * _onePct; // 20%
    }

    function test_setup() public {
        assertEq(debtInFrontHelper.TROVE_MANAGER(), address(troveManager), "E0");
        assertEq(debtInFrontHelper.SORTED_TROVES(), address(sortedTroves), "E1");
    }

    function test_getDebtInFront_noTroves() public {
        // With no troves, debt in front should be 0
        uint256 _debt = debtInFrontHelper.get_debt_in_front(0, rate1, 0, 0, 0);
        assertEq(_debt, 0, "E0");
    }

    function test_getDebtInFront_singleTrove() public {
        // Lend some to the lender
        uint256 _borrowAmount = troveManager.min_debt();
        mintAndDepositIntoLender(userLender, _borrowAmount);

        // Calculate collateral needed
        uint256 _collateralNeeded =
            (_borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open a single trove at rate1
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, rate1);

        // Get the trove's debt (with interest)
        uint256 _troveDebt = troveManager.get_trove_debt_after_interest(_troveId);

        // Debt in front of rate1 (rates < rate1) should be 0
        uint256 _debtInFront = debtInFrontHelper.get_debt_in_front(0, rate1, 0, 0, 0);
        assertEq(_debtInFront, 0, "E0");

        // Debt in front of rate2 (rates < rate2) should include the trove at rate1
        _debtInFront = debtInFrontHelper.get_debt_in_front(0, rate2, 0, 0, 0);
        assertEq(_debtInFront, _troveDebt, "E1");
    }

    function test_getDebtInFront_multipleTroves() public {
        // Lend enough for 3 troves
        uint256 _borrowAmount = troveManager.min_debt();
        mintAndDepositIntoLender(userLender, _borrowAmount * 3);

        // Calculate collateral needed per trove
        uint256 _collateralNeeded =
            (_borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open 3 troves at different rates
        uint256 _troveId1 = mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, rate1);
        uint256 _troveId2 = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _borrowAmount, rate2);
        uint256 _troveId3 = mintAndOpenTrove(liquidator, _collateralNeeded, _borrowAmount, rate3);

        // Get each trove's debt
        uint256 _debt1 = troveManager.get_trove_debt_after_interest(_troveId1);
        uint256 _debt2 = troveManager.get_trove_debt_after_interest(_troveId2);
        uint256 _debt3 = troveManager.get_trove_debt_after_interest(_troveId3);

        // Debt in front of rate1 should be 0 (no troves with rate < rate1)
        uint256 _debtInFront = debtInFrontHelper.get_debt_in_front(0, rate1, 0, 0, 0);
        assertEq(_debtInFront, 0, "E0");

        // Debt in front of rate2 should be _debt1
        _debtInFront = debtInFrontHelper.get_debt_in_front(0, rate2, 0, 0, 0);
        assertEq(_debtInFront, _debt1, "E1");

        // Debt in front of rate3 should be _debt1 + _debt2
        _debtInFront = debtInFrontHelper.get_debt_in_front(0, rate3, 0, 0, 0);
        assertEq(_debtInFront, _debt1 + _debt2, "E2");

        // Debt in front of rate4 should be _debt1 + _debt2 + _debt3
        _debtInFront = debtInFrontHelper.get_debt_in_front(0, rate4, 0, 0, 0);
        assertEq(_debtInFront, _debt1 + _debt2 + _debt3, "E3");
    }

    function test_getDebtInFront_stopAtTrove() public {
        // Lend enough for 3 troves
        uint256 _borrowAmount = troveManager.min_debt();
        mintAndDepositIntoLender(userLender, _borrowAmount * 3);

        // Calculate collateral needed per trove
        uint256 _collateralNeeded =
            (_borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open 3 troves at different rates
        uint256 _troveId1 = mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, rate1);
        uint256 _troveId2 = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _borrowAmount, rate2);
        mintAndOpenTrove(liquidator, _collateralNeeded, _borrowAmount, rate3);

        // Get each trove's debt
        uint256 _debt1 = troveManager.get_trove_debt_after_interest(_troveId1);

        // Debt in front of trove2 (stop at trove2) should be _debt1
        uint256 _debtInFront = debtInFrontHelper.get_debt_in_front(0, rate4, _troveId2, 0, 0);
        assertEq(_debtInFront, _debt1, "E0");

        // Debt in front of trove1 (stop at trove1) should be 0
        _debtInFront = debtInFrontHelper.get_debt_in_front(0, rate4, _troveId1, 0, 0);
        assertEq(_debtInFront, 0, "E1");
    }

    function test_getDebtInFront_interestRateRange() public {
        // Lend enough for 3 troves
        uint256 _borrowAmount = troveManager.min_debt();
        mintAndDepositIntoLender(userLender, _borrowAmount * 3);

        // Calculate collateral needed per trove
        uint256 _collateralNeeded =
            (_borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Open 3 troves at different rates
        uint256 _troveId1 = mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, rate1);
        uint256 _troveId2 = mintAndOpenTrove(anotherUserBorrower, _collateralNeeded, _borrowAmount, rate2);
        mintAndOpenTrove(liquidator, _collateralNeeded, _borrowAmount, rate3);

        // Get trove debts
        uint256 _debt1 = troveManager.get_trove_debt_after_interest(_troveId1);
        uint256 _debt2 = troveManager.get_trove_debt_after_interest(_troveId2);

        // Debt between rate1 and rate3 includes troves with rate >= rate1 AND rate < rate3
        // So it includes trove1 (rate1) and trove2 (rate2), but not trove3 (rate3)
        uint256 _debtInRange = debtInFrontHelper.get_debt_in_front(rate1, rate3, 0, 0, 0);
        assertEq(_debtInRange, _debt1 + _debt2, "E0");
    }

}
