// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IBaseStrategy} from "@tokenized-strategy/interfaces/IBaseStrategy.sol";

import {IAuction} from "../script/interfaces/IAuction.sol";

import {AuctionFactory} from "./Mocks/AuctionFactory.sol";

import "../script/Deploy.s.sol";

import "forge-std/Test.sol";

abstract contract Base is Deploy, Test {

    address public userLender = address(420);
    address public userBorrower = address(69);
    address public anotherUserBorrower = address(555);
    address public liquidator = address(88);

    // Fuzz lend amount from 0.001 of 1e18 coin up to 1 million of a 1e18 coin
    uint256 public maxFuzzAmount = 1_000_000 ether;
    uint256 public minFuzzAmount = 0.001 ether;

    uint256 public minDebtFuzzAmount;
    uint256 public borrowTokenDecimals;
    uint256 public collateralTokenDecimals;

    uint256 public DEFAULT_ANNUAL_INTEREST_RATE;
    uint256 public DEFAULT_TARGET_COLLATERAL_RATIO;

    uint256 public constant MAX_LIQUIDATION_BATCH_SIZE = 50;

    function setUp() public virtual {
        // notify deplyment script that this is a test
        isTest = true;

        // create fork
        uint256 _blockNumber = 23_513_850; // cache state for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        // Deploy auction factory with minimumPrice and setReceiver
        auctionFactory = address(new AuctionFactory());

        // deploy and initialize contracts
        run();

        // Set up Lender
        vm.prank(management);
        lender.acceptManagement();

        // Set up "constants" for tests
        DEFAULT_ANNUAL_INTEREST_RATE = troveManager.MIN_ANNUAL_INTEREST_RATE() * 2; // 1%
        DEFAULT_TARGET_COLLATERAL_RATIO = troveManager.MINIMUM_COLLATERAL_RATIO() * 110 / 100; // 10% above MCR

        // Make sure Lender's deposit limit does not interfere with tests
        vm.mockCall(address(lender), abi.encodeWithSelector(IBaseStrategy.availableDepositLimit.selector), abi.encode(type(uint256).max));

        // Get token decimals
        borrowTokenDecimals = IERC20Metadata(address(borrowToken)).decimals();
        collateralTokenDecimals = IERC20Metadata(address(collateralToken)).decimals();

        // Adjust fuzz amounts based on tokens decimals
        minDebtFuzzAmount = troveManager.MIN_DEBT();
        uint256 _borrowTokenDecimals = IERC20Metadata(address(borrowToken)).decimals();
        if (_borrowTokenDecimals < 18) {
            uint256 _adjustment = 10 ** (18 - _borrowTokenDecimals);
            maxFuzzAmount = maxFuzzAmount / _adjustment;
            minFuzzAmount = minFuzzAmount / _adjustment;
            minDebtFuzzAmount = minDebtFuzzAmount / _adjustment;
        }
    }

    function airdrop(
        address _token,
        address _to,
        uint256 _amount
    ) public {
        airdrop(_token, _to, _amount, false);
    }

    function airdrop(
        address _token,
        address _to,
        uint256 _amount,
        bool _addToBalance
    ) public {
        if (_token == address(0)) {
            uint256 _balanceBefore = _addToBalance ? _to.balance : 0;
            vm.deal(_to, _balanceBefore + _amount);
        } else {
            uint256 _balanceBefore = _addToBalance ? IERC20(_token).balanceOf(_to) : 0;
            deal({token: _token, to: _to, give: _balanceBefore + _amount});
        }
    }

    function takeAuction(
        address _auction
    ) public returns (uint256) {
        // Skip time to reach market price
        // Calculate the number of steps needed to reach oracle price
        uint256 _stepDuration = IAuction(_auction).stepDuration();
        uint256 _targetPrice = priceOracle.price();
        uint256 _currentPrice = _scaleTo18Decimals(IAuction(_auction).price(address(collateralToken)), borrowTokenDecimals);
        uint256 _steps = 0;

        // Iterate step-by-step until price reaches target
        while (_currentPrice > _targetPrice && _steps < 1440) {
            // Max 1440 steps (1 day at 60s/step)
            _steps++;
            _currentPrice =
                _scaleTo18Decimals(IAuction(_auction).price(address(collateralToken), block.timestamp + _steps * _stepDuration), borrowTokenDecimals);
            if (_currentPrice == 0) break; // Price went below minimum
        }

        // Skip to the found time
        if (_steps > 0) skip(_steps * _stepDuration);

        uint256 _amountNeeded = IAuction(_auction).getAmountNeeded(address(collateralToken));
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(_auction, _amountNeeded);
        IAuction(_auction).take(address(collateralToken));
        vm.stopPrank();

        // Return the time skipped
        return _steps * _stepDuration;
    }

    function depositIntoLender(
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        borrowToken.approve(address(lender), _amount);

        uint256 _totalAssetsBefore = lender.totalAssets();

        vm.prank(_user);
        lender.deposit(_amount, _user);

        assertEq(lender.totalAssets(), _totalAssetsBefore + _amount, "!totalAssets");
    }

    function mintAndDepositIntoLender(
        address _user,
        uint256 _amount
    ) public {
        airdrop(address(borrowToken), _user, _amount);
        depositIntoLender(_user, _amount);
    }

    function mintAndOpenTrove(
        address _user,
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        uint256 _annualInterestRate
    ) public returns (uint256 _troveId) {
        return _mintAndOpenTrove(_user, _collateralAmount, _borrowAmount, _annualInterestRate);
    }

    function _mintAndOpenTrove(
        address _user,
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        uint256 _annualInterestRate
    ) internal returns (uint256 _troveId) {
        // Scale collateral amount to token decimals with rounding up
        uint256 _descaledCollateralAmount = _scaleFrom18Decimals(_collateralAmount, collateralTokenDecimals, true);

        // Airdrop some collateral to borrower
        airdrop(address(collateralToken), _user, _descaledCollateralAmount);

        // Open a trove
        vm.startPrank(_user);
        collateralToken.approve(address(troveManager), _descaledCollateralAmount);
        _troveId = troveManager.open_trove(
            block.timestamp, // owner_index
            _descaledCollateralAmount, // collateral_amount
            _borrowAmount, // debt_amount
            0, // upper_hint
            0, // lower_hint
            _annualInterestRate, // annual_interest_rate
            type(uint256).max // max_upfront_fee
        );
        vm.stopPrank();
    }

    // Same as `_get_upfront_fee` in `trove_manager.vy`
    function _getUpfrontFee18Decimals(
        uint256 _debtAmount,
        uint256 _annualInterestRate
    ) internal view returns (uint256) {
        // Scale `debtAmount` to 18 decimals
        uint256 _scaledDebtAmount = _scaleTo18Decimals(_debtAmount, borrowTokenDecimals);

        // Total debt after adding the new debt
        uint256 _newTotalDebt = troveManager.total_debt() + _scaledDebtAmount;

        // Total weighted debt after adding the new weighted debt
        uint256 _newTotalWeightedDebt = troveManager.total_weighted_debt() + (_scaledDebtAmount * _annualInterestRate);

        // Calculate the new average interest rate
        uint256 _avgInterestRate = _newTotalWeightedDebt / _newTotalDebt;

        // Calculate the upfront fee using the average interest rate
        uint256 _upfrontFee = _calculateAccruedInterest(_scaledDebtAmount * _avgInterestRate, troveManager.UPFRONT_INTEREST_PERIOD());

        return _upfrontFee;
    }

    // Returns collateral needed in 18 decimals (round-tripped to match stored value)
    function _getCollateralNeeded18Decimals(
        uint256 _borrowAmount
    ) internal view returns (uint256) {
        return _getCollateralNeededWithRatio18Decimals(_borrowAmount, DEFAULT_TARGET_COLLATERAL_RATIO);
    }

    // Returns collateral needed in 18 decimals with custom collateral ratio (round-tripped to match stored value)
    function _getCollateralNeededWithRatio18Decimals(
        uint256 _borrowAmount,
        uint256 _targetCollateralRatio
    ) internal view returns (uint256) {
        uint256 _collateral18d = _scaleTo18Decimals(_borrowAmount, borrowTokenDecimals) * _targetCollateralRatio / priceOracle.price();
        return _roundTripCollateral(_collateral18d);
    }

    // Returns expected debt in 18 decimals
    function _getExpectedDebt18Decimals(
        uint256 _borrowAmount
    ) internal view returns (uint256) {
        return _scaleTo18Decimals(_borrowAmount, borrowTokenDecimals) + _getUpfrontFee18Decimals(_borrowAmount, DEFAULT_ANNUAL_INTEREST_RATE);
    }

    // Same as `_calculate_accrued_interest` in `trove_manager.vy`
    function _calculateAccruedInterest(
        uint256 _weightedDebt,
        uint256 _period
    ) internal pure returns (uint256) {
        return (_weightedDebt * _period) / 365 days / 1e18;
    }

    function _scaleTo18Decimals(
        uint256 _amount,
        uint256 _decimals
    ) internal pure returns (uint256) {
        return _decimals < 18 ? _amount * (10 ** (18 - _decimals)) : _amount;
    }

    function _scaleFrom18Decimals(
        uint256 _amount,
        uint256 _decimals,
        bool _roundUp
    ) internal pure returns (uint256) {
        if (_decimals > 18) {
            return _amount;
        } else {
            uint256 _scaleFactor = 10 ** (18 - _decimals);
            if (_roundUp) return (_amount + _scaleFactor - 1) / _scaleFactor;
            else return _amount / _scaleFactor;
        }
    }

    // Simulates the round-trip: 18d → native decimals (round up) → back to 18d
    // This matches what the contract stores after a deposit
    function _roundTripCollateral(
        uint256 _amount18d
    ) internal view returns (uint256) {
        uint256 _native = _scaleFrom18Decimals(_amount18d, collateralTokenDecimals, true);
        return _scaleTo18Decimals(_native, collateralTokenDecimals);
    }

}
