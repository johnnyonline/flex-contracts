// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";
import {IPriceOracleNotScaled} from "./interfaces/IPriceOracleNotScaled.sol";
import {IPriceOracleScaled} from "./interfaces/IPriceOracleScaled.sol";

contract GasTests is Base {

    uint256 constant MAX_GAS = 7_000_000;
    uint256 constant GAS_PRICE = 1 gwei;

    function setUp() public override {
        Base.setUp();
    }

    function test_gas_redeem() public {
        uint256 _minDebt = troveManager.min_debt();
        uint256 _rate = DEFAULT_ANNUAL_INTEREST_RATE;
        uint256 _numTroves = 700;

        uint256 _lenderDeposit = _minDebt * _numTroves;

        // Fund lender
        mintAndDepositIntoLender(userLender, _lenderDeposit);

        // Create troves - each borrows _minDebt
        uint256 _troveId;
        for (uint256 i = 0; i < _numTroves; i++) {
            uint256 _collateralNeeded =
                (_minDebt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

            address _user = address(uint160(i + 1000));
            _troveId = mintAndOpenTrove(_user, _collateralNeeded, _minDebt, _rate);
        }

        // Lender redeems everything they deposited
        vm.prank(userLender);
        uint256 _gasBefore = gasleft();
        lender.redeem(_lenderDeposit, userLender, userLender);
        uint256 _gasUsed = _gasBefore - gasleft();

        emit log_named_uint("Troves", _numTroves);
        emit log_named_uint("Gas used", _gasUsed);
        emit log_named_uint("Cost in ETH (wei)", _gasUsed * GAS_PRICE);

        assertLt(_gasUsed, MAX_GAS, "Exceeded 7M gas limit");
    }

    function test_gas_openTrove() public {
        uint256 _minDebt = troveManager.min_debt();
        uint256 _rate = DEFAULT_ANNUAL_INTEREST_RATE;
        uint256 numTroves = 700;

        uint256 _lenderDeposit = _minDebt * (numTroves + 1);

        // Fund lender
        mintAndDepositIntoLender(userLender, _lenderDeposit);

        // Initialize variable
        uint256 _collateralNeeded;

        // Create troves
        for (uint256 i = 0; i < numTroves; i++) {
            _collateralNeeded = (_minDebt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

            address _user = address(uint160(i + 1000));
            mintAndOpenTrove(_user, _collateralNeeded, _minDebt, _rate);
        }

        // Last trove opens with all remaining debt - measure gas for this one
        _collateralNeeded = (_minDebt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        address _lastUser = address(uint160(numTroves + 1000));
        deal(address(collateralToken), _lastUser, _collateralNeeded);

        vm.startPrank(_lastUser);
        collateralToken.approve(address(troveManager), _collateralNeeded);

        uint256 gasBefore = gasleft();
        troveManager.open_trove(block.timestamp, _collateralNeeded, _minDebt, 0, 0, _rate, type(uint256).max, 0, 0);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        emit log_named_uint("Existing troves", numTroves);
        emit log_named_uint("Gas used", gasUsed);
        emit log_named_uint("Cost in ETH (wei)", gasUsed * GAS_PRICE);

        assertLt(gasUsed, MAX_GAS, "Exceeded 7M gas limit");
    }

}
