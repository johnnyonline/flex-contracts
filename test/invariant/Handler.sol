// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

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

    uint256 public minDebt;
    uint256 public minRate;
    uint256 public maxRate;
    uint256 public borrowTokenPrecision;
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
        address _lender
    ) {
        troveManager = _troveManager;
        priceOracle = _priceOracle;
        borrowToken = _borrowToken;
        collateralToken = _collateralToken;
        lender = _lender;

        minDebt = troveManager.MIN_DEBT();
        minRate = troveManager.MIN_ANNUAL_INTEREST_RATE();
        maxRate = troveManager.MAX_ANNUAL_INTEREST_RATE();
        borrowTokenPrecision = 10 ** IERC20Metadata(address(borrowToken)).decimals();
        minimumCollateralRatio = troveManager.MINIMUM_COLLATERAL_RATIO();
    }

    // ============================================================================================
    // Trove Management
    // ============================================================================================

    function openTrove(
        uint256 _debt,
        uint256 _rate,
        uint256 _seed
    ) external {
        _debt = bound(_debt, minDebt + 1, 1_000_000 * borrowTokenPrecision);
        _rate = bound(_rate, minRate, maxRate);

        address _user = address(uint160(bound(_seed, 1000, type(uint160).max)));
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
        _amount = bound(_amount, 1, 1_000_000 * borrowTokenPrecision);

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
