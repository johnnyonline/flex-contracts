// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IBaseStrategy} from "@tokenized-strategy/interfaces/IBaseStrategy.sol";

import {ILender} from "../src/lender/interfaces/ILender.sol";

import {IAuction} from "./interfaces/IAuction.sol";
import {IDutchDesk} from "./interfaces/IDutchDesk.sol";
import {IKeeper} from "./interfaces/IKeeper.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISortedTroves} from "./interfaces/ISortedTroves.sol";
import {ITroveManager} from "./interfaces/ITroveManager.sol";

import "../script/Deploy.s.sol";

import "forge-std/Test.sol";

abstract contract Base is Deploy, Test {

    // Contracts
    ILender public lender;
    IPriceOracle public priceOracle;
    IAuction public auction;
    IDutchDesk public dutchDesk;
    ISortedTroves public sortedTroves;
    ITroveManager public troveManager;

    // Roles
    address public userLender = address(420);
    address public userBorrower = address(69);
    address public anotherUserBorrower = address(555);
    address public liquidator = address(88);
    address public management = address(420_420);
    address public performanceFeeRecipient = address(420_69_420);
    address public keeper = address(69_69);

    // Market parameters
    uint256 public minimumDebt = 500; // 500 tokens
    uint256 public minimumCollateralRatio = 110; // 110%
    uint256 public upfrontInterestPeriod = 7 days; // 7 days
    uint256 public interestRateAdjCooldown = 7 days; // 7 days
    uint256 public liquidatorFeePercentage = 1e15; // 0.1%
    uint256 public minimumPriceBufferPercentage = 1e18 - 5e16; // 5%
    uint256 public startingPriceBufferPercentage = 1e18 + 15e16; // 5%
    uint256 public emergencyStartingPriceBufferPercentage = 1e18 + 20e16; // 20%
    uint256 public stepDuration = 20; // 20 seconds
    uint256 public stepDecayRate = 20; // 0.2%
    uint256 public auctionLength = 1 days; // 1 day

    // Fuzz lend amount from 0.001 of 1e18 coin up to 1 million of a 1e18 coin
    uint256 public maxFuzzAmount = 1_000_000 ether;
    uint256 public minFuzzAmount = 0.001 ether;

    uint256 public BORROW_TOKEN_PRECISION;
    uint256 public COLLATERAL_TOKEN_PRECISION;
    uint256 public DEFAULT_ANNUAL_INTEREST_RATE;
    uint256 public DEFAULT_TARGET_COLLATERAL_RATIO;

    uint256 public constant MAX_ITERATIONS = 700;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant WAD = 1e18;

    function setUp() public virtual {
        // Notify deployment script that this is a test
        isTest = true;

        // Create fork
        uint256 _blockNumber = 23_513_850; // cache state for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        // Deploy factories
        run();

        // Deploy price oracle
        priceOracle = IPriceOracle(deployCode("yvweth2_to_usdc_oracle"));

        // Deploy market
        (address _troveManager, address _sortedTroves, address _dutchDesk, address _auction, address _lender) =
            catFactory.deploy(address(borrowToken), address(collateralToken), address(priceOracle), management, performanceFeeRecipient);

        // Set contract instances
        troveManager = ITroveManager(_troveManager);
        sortedTroves = ISortedTroves(_sortedTroves);
        dutchDesk = IDutchDesk(_dutchDesk);
        auction = IAuction(_auction);
        lender = ILender(_lender);

        // Label addresses
        vm.label(address(troveManager), "TroveManager");
        vm.label(address(sortedTroves), "SortedTroves");
        vm.label(address(dutchDesk), "DutchDesk");
        vm.label(address(auction), "Auction");
        vm.label(address(lender), "Lender");

        // Set up Lender
        vm.prank(management);
        lender.acceptManagement();

        // Set up "constants" for tests
        BORROW_TOKEN_PRECISION = 10 ** IERC20Metadata(address(borrowToken)).decimals();
        COLLATERAL_TOKEN_PRECISION = 10 ** IERC20Metadata(address(collateralToken)).decimals();
        DEFAULT_ANNUAL_INTEREST_RATE = troveManager.min_annual_interest_rate() * 2; // 1%
        DEFAULT_TARGET_COLLATERAL_RATIO = troveManager.minimum_collateral_ratio() * 110 / 100; // 10% above MCR

        // Make sure Lender's deposit limit does not interfere with tests
        vm.mockCall(address(lender), abi.encodeWithSelector(IBaseStrategy.availableDepositLimit.selector), abi.encode(type(uint256).max));

        // Adjust fuzzing limits based on borrow token decimals
        if (IERC20Metadata(address(borrowToken)).decimals() < 18) {
            uint256 _decimalsDiff = 18 - IERC20Metadata(address(borrowToken)).decimals();
            maxFuzzAmount = maxFuzzAmount / (10 ** _decimalsDiff);
            minFuzzAmount = minFuzzAmount / (10 ** _decimalsDiff);
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
        uint256 _auctionId
    ) public returns (uint256) {
        // Skip time to reach market price
        // Calculate the number of steps needed to reach oracle price
        uint256 _stepDuration = auction.step_duration();
        uint256 _targetPrice = priceOracle.get_price(false);
        uint256 _currentPrice = auction.get_price(_auctionId, block.timestamp);
        uint256 _steps = 0;

        // Iterate step-by-step until price reaches target
        while (_currentPrice > _targetPrice && _steps < 1440) {
            _steps++;
            _currentPrice = auction.get_price(_auctionId, block.timestamp + _steps * _stepDuration);
        }

        // Skip to the found time
        if (_steps > 0) skip(_steps * _stepDuration);

        uint256 _amountNeeded = auction.get_needed_amount(_auctionId, type(uint256).max, block.timestamp);
        airdrop(address(borrowToken), liquidator, _amountNeeded);
        vm.startPrank(liquidator);
        borrowToken.approve(address(auction), _amountNeeded);
        auction.take(_auctionId, type(uint256).max, liquidator, "");
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
        // Airdrop some collateral to borrower
        airdrop(address(collateralToken), _user, _collateralAmount);

        // Open a trove
        vm.startPrank(_user);
        collateralToken.approve(address(troveManager), _collateralAmount);
        _troveId = troveManager.open_trove(
            block.timestamp, // owner_index
            _collateralAmount, // collateral_amount
            _borrowAmount, // debt_amount
            0, // upper_hint
            0, // lower_hint
            _annualInterestRate, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );
        vm.stopPrank();
    }

}
