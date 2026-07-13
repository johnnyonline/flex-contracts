// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {IPriceOracleNotScaled} from "../interfaces/IPriceOracleNotScaled.sol";
import {IPriceOracleScaled} from "../interfaces/IPriceOracleScaled.sol";

import "../Base.sol";

contract Handler is Test {

    // ============================================================================================
    // Storage
    // ============================================================================================

    ITroveManager public troveManager;
    IPriceOracle public priceOracle;
    IERC20 public borrowToken;
    IERC20 public collateralToken;
    address public lender;
    address public lenderUser;

    uint256 public minDebt;
    uint256 public minRate;
    uint256 public maxRate;
    uint256 public borrowTokenPrecision;
    uint256 public collateralTokenPrecision;
    uint256 public minimumCollateralRatio;

    uint256 public constant ORACLE_PRICE_SCALE = 1e36;

    // Track trove IDs
    uint256[] public troveIds;

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor(
        ITroveManager _troveManager,
        IPriceOracle _priceOracle,
        IERC20 _borrowToken,
        IERC20 _collateralToken,
        address _lender,
        address _lenderUser
    ) {
        troveManager = _troveManager;
        priceOracle = _priceOracle;
        borrowToken = _borrowToken;
        collateralToken = _collateralToken;
        lender = _lender;
        lenderUser = _lenderUser;

        minDebt = troveManager.min_debt();
        minRate = troveManager.min_annual_interest_rate();
        maxRate = troveManager.max_annual_interest_rate();
        borrowTokenPrecision = 10 ** IERC20Metadata(address(borrowToken)).decimals();
        collateralTokenPrecision = 10 ** IERC20Metadata(address(collateralToken)).decimals();
        minimumCollateralRatio = troveManager.minimum_collateral_ratio();
    }

    // ============================================================================================
    // Trove Management
    // ============================================================================================

    function openTrove(
        uint256 _debt,
        uint256 _rate,
        uint256 _seed
    ) external {
        _debt = bound(_debt, minDebt, minDebt * 10);
        _rate = bound(_rate, minRate, maxRate);

        address[3] memory _users = [address(1001), address(1002), address(1003)];
        address _user = _users[bound(_seed, 0, 2)];
        uint256 _targetRatio = minimumCollateralRatio * 120 / 100;
        uint256 _collateral = (_debt * _targetRatio / borrowTokenPrecision) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        deal(address(collateralToken), _user, _collateral);

        vm.startPrank(_user);
        collateralToken.approve(address(troveManager), _collateral);
        try troveManager.open_trove(block.timestamp + troveIds.length, _collateral, _debt, 0, 0, _rate, type(uint256).max, 0, 0) returns (
            uint256 _id
        ) {
            troveIds.push(_id);
        } catch {}
        vm.stopPrank();
    }

    function addCollateral(
        uint256 _troveIndex,
        uint256 _amount
    ) external {
        if (troveIds.length == 0) return;
        _troveIndex = bound(_troveIndex, 0, troveIds.length - 1);
        _amount = bound(_amount, 1, 1_000_000 * collateralTokenPrecision);

        uint256 _troveId = troveIds[_troveIndex];
        address _owner = troveManager.troves(_troveId).owner;

        deal(address(collateralToken), _owner, _amount);

        vm.startPrank(_owner);
        collateralToken.approve(address(troveManager), _amount);
        try troveManager.add_collateral(_troveId, _amount) {} catch {}
        vm.stopPrank();
    }

    function removeCollateral(
        uint256 _troveIndex,
        uint256 _amount
    ) external {
        if (troveIds.length == 0) return;
        _troveIndex = bound(_troveIndex, 0, troveIds.length - 1);

        uint256 _troveId = troveIds[_troveIndex];
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        _amount = bound(_amount, 1, _trove.collateral);

        vm.prank(_trove.owner);
        try troveManager.remove_collateral(_troveId, _amount) {} catch {}
    }

    function borrow(
        uint256 _troveIndex,
        uint256 _amount
    ) external {
        if (troveIds.length == 0) return;
        _troveIndex = bound(_troveIndex, 0, troveIds.length - 1);
        _amount = bound(_amount, 1, 100_000 * borrowTokenPrecision);

        uint256 _troveId = troveIds[_troveIndex];
        address _owner = troveManager.troves(_troveId).owner;

        vm.prank(_owner);
        try troveManager.borrow(_troveId, _amount, type(uint256).max, 0, 0) {} catch {}
    }

    function repay(
        uint256 _troveIndex,
        uint256 _amount
    ) external {
        if (troveIds.length == 0) return;
        _troveIndex = bound(_troveIndex, 0, troveIds.length - 1);

        uint256 _troveId = troveIds[_troveIndex];
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        _amount = bound(_amount, 1, _trove.debt);

        deal(address(borrowToken), _trove.owner, _amount);

        vm.startPrank(_trove.owner);
        borrowToken.approve(address(troveManager), _amount);
        try troveManager.repay(_troveId, _amount) {} catch {}
        vm.stopPrank();
    }

    function adjustInterestRate(
        uint256 _troveIndex,
        uint256 _newRate
    ) external {
        if (troveIds.length == 0) return;
        _troveIndex = bound(_troveIndex, 0, troveIds.length - 1);
        _newRate = bound(_newRate, minRate, maxRate);

        uint256 _troveId = troveIds[_troveIndex];
        address _owner = troveManager.troves(_troveId).owner;

        vm.prank(_owner);
        try troveManager.adjust_interest_rate(_troveId, _newRate, 0, 0, type(uint256).max) {} catch {}
    }

    function closeTrove(
        uint256 _troveIndex
    ) external {
        if (troveIds.length == 0) return;
        _troveIndex = bound(_troveIndex, 0, troveIds.length - 1);

        uint256 _troveId = troveIds[_troveIndex];
        uint256 _debt = troveManager.get_trove_debt_after_interest(_troveId);
        address _owner = troveManager.troves(_troveId).owner;

        deal(address(borrowToken), _owner, _debt);

        vm.startPrank(_owner);
        borrowToken.approve(address(troveManager), _debt);
        try troveManager.close_trove(_troveId) {} catch {}
        vm.stopPrank();
    }

    // ============================================================================================
    // Lender & Protocol fees
    // ============================================================================================

    function lenderDeposit(
        uint256 _amount
    ) external {
        _amount = bound(_amount, 1, minDebt * 10);

        deal(address(borrowToken), lenderUser, _amount);

        vm.startPrank(lenderUser);
        borrowToken.approve(lender, _amount);
        try ILender(lender).deposit(_amount, lenderUser) {} catch {}
        vm.stopPrank();
    }

    function lenderWithdraw(
        uint256 _shares
    ) external {
        uint256 _balance = ILender(lender).balanceOf(lenderUser);
        if (_balance == 0) return;
        _shares = bound(_shares, 1, _balance);

        vm.prank(lenderUser);
        try ILender(lender).redeem(_shares, lenderUser, lenderUser) {} catch {}
    }

    function claimFees() external {
        address _recipient = ILender(lender).performanceFeeRecipient();
        vm.prank(_recipient);
        try troveManager.claim_protocol_fees(0, 0) {} catch {}
    }

    function liquidateUnderwater(
        uint256 _troveIndex,
        uint256 _collateralRatio
    ) external {
        if (troveIds.length == 0) return;
        _troveIndex = bound(_troveIndex, 0, troveIds.length - 1);
        _collateralRatio = bound(_collateralRatio, 1, 104);

        uint256 _troveId = troveIds[_troveIndex];
        ITroveManager.Trove memory _trove = troveManager.troves(_troveId);
        if (_trove.collateral == 0 || _trove.debt == 0) return;

        // Drop the oracle price so the trove sits at the target collateral ratio
        uint256 _price = _collateralRatio * troveManager.one_pct() * _trove.debt * ORACLE_PRICE_SCALE / (_trove.collateral * borrowTokenPrecision);
        uint256 _price18 = _price * collateralTokenPrecision * 1e18 / (ORACLE_PRICE_SCALE * borrowTokenPrecision);
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleScaled.get_price.selector), abi.encode(_price));
        vm.mockCall(address(priceOracle), abi.encodeWithSelector(IPriceOracleNotScaled.get_price.selector, false), abi.encode(_price18));

        deal(address(borrowToken), address(this), _trove.debt);
        borrowToken.approve(address(troveManager), _trove.debt);
        try troveManager.liquidate_trove(_troveId, type(uint256).max, address(this), "") {} catch {}

        vm.clearMockedCalls();
    }

    // ============================================================================================
    // Time & Sync
    // ============================================================================================

    function warp(
        uint256 _time
    ) external {
        _time = bound(_time, 1, 365 days);
        skip(_time);
    }

    function sync() external {
        troveManager.sync_total_debt();
    }

    // ============================================================================================
    // View
    // ============================================================================================

    function getTroveIds() external view returns (uint256[] memory) {
        return troveIds;
    }

    function getTroveCount() external view returns (uint256) {
        return troveIds.length;
    }

}
