// // SPDX-License-Identifier: MIT
// pragma solidity 0.8.23;

// import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
// import {IBaseStrategy} from "@tokenized-strategy/interfaces/IBaseStrategy.sol";

// import "../script/Deploy.s.sol";

// import "forge-std/Test.sol";

// abstract contract Base is Deploy, Test {

//     address public userLender = address(420);
//     address public userBorrower = address(69);
//     address public anotherUserBorrower = address(555);
//     address public liquidator = address(88);

//     // Fuzz lend amount from 0.001 of 1e18 coin up to 1 million of a 1e18 coin
//     uint256 public maxFuzzAmount = 1_000_000 ether;
//     uint256 public minFuzzAmount = 0.001 ether;

//     uint256 public BORROW_TOKEN_PRECISION;
//     uint256 public COLLATERAL_TOKEN_PRECISION;
//     uint256 public DEFAULT_ANNUAL_INTEREST_RATE;
//     uint256 public DEFAULT_TARGET_COLLATERAL_RATIO;

//     uint256 public constant MAX_ITERATIONS = 700;
//     uint256 public constant ORACLE_PRICE_SCALE = 1e36;
//     uint256 public constant WAD = 1e18;

//     function setUp() public virtual {
//         // notify deplyment script that this is a test
//         isTest = true;

//         // create fork
//         uint256 _blockNumber = 23_513_850; // cache state for faster tests
//         vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

//         // deploy and initialize contracts
//         run();

//         // Set up Lender
//         vm.prank(management);
//         lender.acceptManagement();

//         // Set up "constants" for tests
//         BORROW_TOKEN_PRECISION = 10 ** IERC20Metadata(address(borrowToken)).decimals();
//         COLLATERAL_TOKEN_PRECISION = 10 ** IERC20Metadata(address(collateralToken)).decimals();
//         DEFAULT_ANNUAL_INTEREST_RATE = troveManager.MIN_ANNUAL_INTEREST_RATE() * 2; // 1%
//         DEFAULT_TARGET_COLLATERAL_RATIO = troveManager.MINIMUM_COLLATERAL_RATIO() * 110 / 100; // 10% above MCR

//         // Make sure Lender's deposit limit does not interfere with tests
//         vm.mockCall(address(lender), abi.encodeWithSelector(IBaseStrategy.availableDepositLimit.selector), abi.encode(type(uint256).max));

//         // Adjust fuzzing limits based on borrow token decimals
//         if (IERC20Metadata(address(borrowToken)).decimals() < 18) {
//             uint256 _decimalsDiff = 18 - IERC20Metadata(address(borrowToken)).decimals();
//             maxFuzzAmount = maxFuzzAmount / (10 ** _decimalsDiff);
//             minFuzzAmount = minFuzzAmount / (10 ** _decimalsDiff);
//         }
//     }

//     function airdrop(
//         address _token,
//         address _to,
//         uint256 _amount
//     ) public {
//         airdrop(_token, _to, _amount, false);
//     }

//     function airdrop(
//         address _token,
//         address _to,
//         uint256 _amount,
//         bool _addToBalance
//     ) public {
//         if (_token == address(0)) {
//             uint256 _balanceBefore = _addToBalance ? _to.balance : 0;
//             vm.deal(_to, _balanceBefore + _amount);
//         } else {
//             uint256 _balanceBefore = _addToBalance ? IERC20(_token).balanceOf(_to) : 0;
//             deal({token: _token, to: _to, give: _balanceBefore + _amount});
//         }
//     }

//     function takeAuction(
//         address _auction
//     ) public returns (uint256) {
//         // Skip time to reach market price
//         // Calculate the number of steps needed to reach oracle price
//         uint256 _stepDuration = IAuction(_auction).step_duration();
//         uint256 _targetPrice = priceOracle.price(false);
//         uint256 _currentPrice = IAuction(_auction).price(address(collateralToken)) * (WAD / BORROW_TOKEN_PRECISION);
//         uint256 _steps = 0;

//         // Iterate step-by-step until price reaches target
//         while (_currentPrice > _targetPrice && _steps < 1440) {
//             // Max 1440 steps (1 day at 60s/step)
//             _steps++;
//             _currentPrice =
//                 IAuction(_auction).price(address(collateralToken), block.timestamp + _steps * _stepDuration) * (WAD / BORROW_TOKEN_PRECISION);
//             if (_currentPrice == 0) break; // Price went below minimum
//         }

//         // Skip to the found time
//         if (_steps > 0) skip(_steps * _stepDuration);

//         uint256 _amountNeeded = IAuction(_auction).get_amount_needed(address(collateralToken));
//         airdrop(address(borrowToken), liquidator, _amountNeeded);
//         vm.startPrank(liquidator);
//         borrowToken.approve(_auction, _amountNeeded);
//         IAuction(_auction).take(address(collateralToken));
//         vm.stopPrank();

//         // Return the time skipped
//         return _steps * _stepDuration;
//     }

//     function depositIntoLender(
//         address _user,
//         uint256 _amount
//     ) public {
//         vm.prank(_user);
//         borrowToken.approve(address(lender), _amount);

//         uint256 _totalAssetsBefore = lender.totalAssets();

//         vm.prank(_user);
//         lender.deposit(_amount, _user);

//         assertEq(lender.totalAssets(), _totalAssetsBefore + _amount, "!totalAssets");
//     }

//     function mintAndDepositIntoLender(
//         address _user,
//         uint256 _amount
//     ) public {
//         airdrop(address(borrowToken), _user, _amount);
//         depositIntoLender(_user, _amount);
//     }

//     function mintAndOpenTrove(
//         address _user,
//         uint256 _collateralAmount,
//         uint256 _borrowAmount,
//         uint256 _annualInterestRate
//     ) public returns (uint256 _troveId) {
//         return _mintAndOpenTrove(_user, _collateralAmount, _borrowAmount, _annualInterestRate);
//     }

//     function _mintAndOpenTrove(
//         address _user,
//         uint256 _collateralAmount,
//         uint256 _borrowAmount,
//         uint256 _annualInterestRate
//     ) internal returns (uint256 _troveId) {
//         // Airdrop some collateral to borrower
//         airdrop(address(collateralToken), _user, _collateralAmount);

//         // Open a trove
//         vm.startPrank(_user);
//         collateralToken.approve(address(troveManager), _collateralAmount);
//         _troveId = troveManager.open_trove(
//             block.timestamp, // owner_index
//             _collateralAmount, // collateral_amount
//             _borrowAmount, // debt_amount
//             0, // upper_hint
//             0, // lower_hint
//             _annualInterestRate, // annual_interest_rate
//             type(uint256).max // max_upfront_fee
//         );
//         vm.stopPrank();
//     }

// }
