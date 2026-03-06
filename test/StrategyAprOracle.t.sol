// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract StrategyAprOracleTests is Base {

    function test_setup() public {
        assertEq(strategyAprOracle.name(), "Flex Lender Strategy APR Oracle", "E0");
    }

    function test_aprAfterDebtChange_noDebt() public {
        assertEq(strategyAprOracle.aprAfterDebtChange(address(lender), 0), 0, "E0");
    }

    // 1. lend
    // 2. borrow all available liquidity
    // 3. double the deposit --> APR should be cut in half
    // 4. halve the deposit --> APR should double
    function test_aprAfterDebtChange_fullUtilization(
        uint256 _amount,
        uint256 _rate
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);
        _rate = bound(_rate, troveManager.min_annual_interest_rate(), troveManager.max_annual_interest_rate() / 10);

        // Lend
        mintAndDepositIntoLender(userLender, _amount);

        // Borrow everything
        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, _rate);

        uint256 _apr = strategyAprOracle.aprAfterDebtChange(address(lender), 0);

        // Full utilization --> APR should equal the rate we're paying
        assertApproxEqRel(_apr, _rate * WAD / BORROW_TOKEN_PRECISION, 5e15, "E0"); // 0.5%

        // Double the deposit --> APR should be cut in half
        uint256 _totalAssets = lender.totalAssets();
        assertApproxEqRel(strategyAprOracle.aprAfterDebtChange(address(lender), int256(_totalAssets)), _apr / 2, 5e15, "E1"); // 0.5%

        // Halve the deposit --> APR should double
        assertApproxEqRel(strategyAprOracle.aprAfterDebtChange(address(lender), -int256(_totalAssets / 2)), _apr * 2, 5e15, "E2"); // 0.5%
    }

    // 1. lend
    // 2. borrow half the available liquidity
    // 3. double the deposit --> APR should be cut in half
    // 4. halve the deposit --> APR should double
    function test_aprAfterDebtChange_partialUtilization(
        uint256 _amount,
        uint256 _rate
    ) public {
        _amount = bound(_amount, troveManager.min_debt() * 2, maxFuzzAmount);
        _rate = bound(_rate, troveManager.min_annual_interest_rate(), troveManager.max_annual_interest_rate() / 10);

        // Lend
        mintAndDepositIntoLender(userLender, _amount);

        // Borrow half
        uint256 _borrowAmount = _amount / 2;
        uint256 _collateralNeeded =
            (_borrowAmount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(userBorrower, _collateralNeeded, _borrowAmount, _rate);

        uint256 _apr = strategyAprOracle.aprAfterDebtChange(address(lender), 0);

        // Half utilization --> APR should be half the rate
        assertApproxEqRel(_apr, _rate * WAD / BORROW_TOKEN_PRECISION / 2, 5e15, "E0"); // 0.5%

        // Double the deposit --> APR should be cut in half
        uint256 _totalAssets = lender.totalAssets();
        assertApproxEqRel(strategyAprOracle.aprAfterDebtChange(address(lender), int256(_totalAssets)), _apr / 2, 5e15, "E1"); // 0.5%

        // Halve the deposit --> APR should double
        assertApproxEqRel(strategyAprOracle.aprAfterDebtChange(address(lender), -int256(_totalAssets / 2)), _apr * 2, 5e15, "E2"); // 0.5%
    }

    function test_aprAfterDebtChange_revertsOnExcessiveNegativeDelta(
        uint256 _amount
    ) public {
        _amount = bound(_amount, troveManager.min_debt(), maxFuzzAmount);

        // Lend and borrow
        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateralNeeded =
            (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        mintAndOpenTrove(userBorrower, _collateralNeeded, _amount, DEFAULT_ANNUAL_INTEREST_RATE);

        // Delta exceeds totalAssets — should revert
        uint256 _totalAssets = lender.totalAssets();
        vm.expectRevert();
        strategyAprOracle.aprAfterDebtChange(address(lender), -int256(_totalAssets + 1));
    }

}
