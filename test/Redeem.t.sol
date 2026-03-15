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
