// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "../Base.sol";

contract Handler is Test {

    ITroveManager public troveManager;
    IPriceOracle public priceOracle;
    IERC20 public borrowToken;
    IERC20 public collateralToken;

    uint256 public minDebt;
    uint256 public minRate;
    uint256 public maxRate;
    uint256 public borrowTokenPrecision;
    uint256 public minimumCollateralRatio;

    uint256 public constant ORACLE_PRICE_SCALE = 1e36;

    uint256[] public troveIds;

    constructor(
        ITroveManager _troveManager,
        IPriceOracle _priceOracle,
        IERC20 _borrowToken,
        IERC20 _collateralToken
    ) {
        troveManager = _troveManager;
        priceOracle = _priceOracle;
        borrowToken = _borrowToken;
        collateralToken = _collateralToken;

        minDebt = troveManager.MIN_DEBT();
        minRate = troveManager.MIN_ANNUAL_INTEREST_RATE();
        maxRate = troveManager.MAX_ANNUAL_INTEREST_RATE();
        borrowTokenPrecision = 10 ** IERC20Metadata(address(borrowToken)).decimals();
        minimumCollateralRatio = troveManager.MINIMUM_COLLATERAL_RATIO();
    }

    function openTrove(uint256 _debt, uint256 _rate, uint256 _seed) external {
        _debt = bound(_debt, minDebt + 1, 1_000_000 * borrowTokenPrecision);
        _rate = bound(_rate, minRate, maxRate);

        address _user = address(uint160(bound(_seed, 1000, type(uint160).max)));
        uint256 _targetRatio = minimumCollateralRatio * 120 / 100;
        uint256 _collateral = (_debt * _targetRatio / borrowTokenPrecision) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        deal(address(collateralToken), _user, _collateral);

        vm.startPrank(_user);
        collateralToken.approve(address(troveManager), _collateral);
        try troveManager.open_trove(
            block.timestamp + troveIds.length,
            _collateral,
            _debt,
            0, 0,
            _rate,
            type(uint256).max,
            0, 0
        ) returns (uint256 _id) {
            troveIds.push(_id);
        } catch {}
        vm.stopPrank();
    }

    function warp(uint256 _time) external {
        _time = bound(_time, 1, 365 days);
        skip(_time);
    }

    function sync() external {
        troveManager.sync_total_debt();
    }

    function getTroveIds() external view returns (uint256[] memory) {
        return troveIds;
    }
}

contract TotalDebtGeSumTroveDebtsInvariantTemp is StdInvariant, Base {

    Handler public handler;

    function setUp() public override {
        Base.setUp();

        mintAndDepositIntoLender(userLender, maxFuzzAmount * 100);

        handler = new Handler(troveManager, priceOracle, borrowToken, collateralToken);

        targetContract(address(handler));
    }

    function invariant_totalDebtGeSumTroveDebts() external {
        uint256[] memory _ids = handler.getTroveIds();
        if (_ids.length == 0) return;

        uint256 _totalDebt = troveManager.total_debt();

        uint256 _sum = 0;
        for (uint256 i = 0; i < _ids.length; i++) {
            _sum += troveManager.get_trove_debt_after_interest(_ids[i]);
        }

        assertGe(_totalDebt, _sum, "CRITICAL: sum(trove debts) > total_debt");
    }
}
