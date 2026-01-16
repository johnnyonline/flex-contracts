// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import "./Base.sol";

contract DebtInvariantHandler is Test {

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

    uint256[] public troveIds;
    uint256 public troveCount;

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

    function openTrove(uint256 _debtAmount, uint256 _rate, uint256 _ownerSeed) external {
        _debtAmount = bound(_debtAmount, minDebt + 1, 1_000_000 * borrowTokenPrecision);
        _rate = bound(_rate, minRate, maxRate);

        address _user = address(uint160(bound(_ownerSeed, 1000, type(uint160).max)));

        uint256 _targetRatio = minimumCollateralRatio * 120 / 100;
        uint256 _collateralNeeded = (_debtAmount * _targetRatio / borrowTokenPrecision) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        deal(address(collateralToken), _user, _collateralNeeded);

        vm.startPrank(_user);
        collateralToken.approve(address(troveManager), _collateralNeeded);

        try troveManager.open_trove(
            block.timestamp + troveCount,
            _collateralNeeded,
            _debtAmount,
            0,
            0,
            _rate,
            type(uint256).max,
            0,
            0
        ) returns (uint256 _troveId) {
            troveIds.push(_troveId);
            troveCount++;
        } catch {}

        vm.stopPrank();
    }

    function skipTimeAndSync(uint256 _timeToSkip) external {
        _timeToSkip = bound(_timeToSkip, 1, 365 days);
        skip(_timeToSkip);
        troveManager.sync_total_debt();
    }

    function getTroveIds() external view returns (uint256[] memory) {
        return troveIds;
    }

    function getTroveCount() external view returns (uint256) {
        return troveCount;
    }
}

contract DebtInvariant2 is StdInvariant, Base {

    DebtInvariantHandler public handler;

    function setUp() public override {
        Base.setUp();

        mintAndDepositIntoLender(userLender, maxFuzzAmount * 100);

        handler = new DebtInvariantHandler(
            troveManager,
            priceOracle,
            borrowToken,
            collateralToken,
            address(lender)
        );

        targetContract(address(handler));
    }

    function invariant_totalDebtGreaterThanOrEqualSumOfTroveDebts() external {
        uint256[] memory _troveIds = handler.getTroveIds();
        uint256 _troveCount = handler.getTroveCount();

        if (_troveCount == 0) return;

        uint256 _totalDebtFromContract = troveManager.total_debt();

        uint256 _sumOfTroveDebts = 0;
        for (uint256 i = 0; i < _troveCount; i++) {
            uint256 _troveDebt = troveManager.get_trove_debt_after_interest(_troveIds[i]);
            _sumOfTroveDebts += _troveDebt;
        }

        assertGe(
            _totalDebtFromContract,
            _sumOfTroveDebts,
            "CRITICAL: sum(trove debts) > total_debt - system is insolvent!"
        );
    }
}
