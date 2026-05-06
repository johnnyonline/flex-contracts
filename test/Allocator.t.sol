// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/console2.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IStrategy} from "../src/allocator/interfaces/IStrategy.sol";
import {ILender} from "../src/lender/interfaces/ILender.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ITroveManager} from "./interfaces/ITroveManager.sol";

import "../script/DeployAllocator.s.sol";

import "forge-std/Test.sol";

contract AllocatorTests is DeployAllocator, Test {

    // Contracts
    ERC20 public asset;
    IStrategy public strategy;
    ILender public constant LENDER = ILender(0x69671A4dA351b64026302f6aC24827620c3C7665);

    // Roles
    address public user = address(1);
    address public management = address(420);
    address public performanceFeeRecipient = address(42069);
    

    // Fuzz bounds
    uint256 public maxFuzzAmount = 1_000_000 ether;
    uint256 public minFuzzAmount = 1 ether;

    uint256 public MAX_BPS = 10_000;
    uint256 public ASSET_PRECISION;

    function setUp() public {
        // Notify deployment script that this is a test
        isTest = true;

        // Create fork
        uint256 _blockNumber = 24_541_660; // cache state for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        // Deploy the StrategyFactory
        run();

        // Deploy a Strategy wrapping the on-chain Lender
        strategy = IStrategy(strategyFactory.deploy(LENDER.asset(), address(LENDER), management, performanceFeeRecipient, "Flex Lender Strategy"));
        asset = ERC20(strategy.asset());
        ASSET_PRECISION = 10 ** asset.decimals();

        vm.label(address(LENDER), "Lender");
        vm.label(address(strategy), "Strategy");
        vm.label(address(asset), "Asset");

        // Accept management and set allowed
        vm.startPrank(management);
        strategy.acceptManagement();
        strategy.setAllowed(user, true);
        vm.stopPrank();

        // Make sure the Lender's deposit limit doesn't constrain the fuzz range
        vm.prank(LENDER.management());
        LENDER.setDepositLimit(type(uint256).max);

        // Adjust fuzzing limits based on asset decimals
        if (asset.decimals() < 18) {
            uint256 _decimalsDiff = 18 - asset.decimals();
            maxFuzzAmount = maxFuzzAmount / (10 ** _decimalsDiff);
            minFuzzAmount = minFuzzAmount / (10 ** _decimalsDiff);
        }
    }

    function test_setupStrategyOK() public {
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), strategyFactory.KEEPER());
    }

    function test_operation(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(1 days);

        // Simulate yield by airdropping the asset directly to the strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(1 days);

        // Simulate yield by airdropping the asset directly to the strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        vm.prank(performanceFeeRecipient);
        strategy.redeem(expectedShares, performanceFeeRecipient, performanceFeeRecipient);

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(asset.balanceOf(performanceFeeRecipient), expectedShares, "!perf fee out");
    }

    function test_shutdownCanWithdraw(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_emergencyWithdraw_maxUint(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    // ============================================================================================
    // Allocator-specific tests
    // ============================================================================================

    // 1. open deposits
    // 2. user deposits
    // 3. expect funds forwarded to the Lender via `_deployFunds`
    function test_deposit(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Fund the user
        airdrop(asset, user, _amount);

        uint256 _lenderSharesBefore = LENDER.balanceOf(address(strategy));

        // Deposit
        vm.startPrank(user);
        asset.approve(address(strategy), _amount);
        strategy.deposit(_amount, user);
        vm.stopPrank();

        // All asset went to the Lender, strategy holds new Lender shares,
        // totalAssets ≈ _amount (subject to Lender PPS rounding)
        assertEq(asset.balanceOf(address(strategy)), 0, "E0");
        assertGt(LENDER.balanceOf(address(strategy)), _lenderSharesBefore, "E1");
        assertApproxEqAbs(strategy.totalAssets(), _amount, 1, "E2");
    }

    // 1. user deposits
    // 2. user redeems
    // 3. expect funds returned via the Lender's idle path (no auction kicked)
    function test_redeem_idleOnly(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        airdrop(asset, user, _amount);

        vm.startPrank(user);
        asset.approve(address(strategy), _amount);
        uint256 _shares = strategy.deposit(_amount, user);

        // The deposit lands in the Lender's idle (forwarded by the strategy), so redeem
        // should succeed via the idle path without kicking a collateral redemption
        uint256 _balanceBefore = asset.balanceOf(user);
        strategy.redeem(_shares, user, user);
        vm.stopPrank();

        // Depositor got their funds back (within Lender PPS rounding)
        assertApproxEqAbs(asset.balanceOf(user) - _balanceBefore, _amount, 1, "E0");
    }

    // 1. seed the strategy with deposits
    // 2. management calls forceFreeFunds
    // 3. expect Lender shares to drop and asset to land on the strategy
    function test_forceFreeFunds(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        airdrop(asset, user, _amount);

        vm.startPrank(user);
        asset.approve(address(strategy), _amount);
        strategy.deposit(_amount, user);
        vm.stopPrank();

        uint256 _lenderSharesBefore = LENDER.balanceOf(address(strategy));

        // Force free the full amount
        vm.prank(management);
        uint256 _freed = strategy.forceFreeFunds(_amount);

        assertLt(LENDER.balanceOf(address(strategy)), _lenderSharesBefore, "E0");
        assertApproxEqAbs(_freed, _amount, 1, "E1");
        assertApproxEqAbs(asset.balanceOf(address(strategy)), _freed, 1, "E2");
    }

    // 1. airdrop idle to the strategy
    // 2. management calls deployIdleFunds with various requests
    // 3. expect deploy capped by min(idle, lender deposit limit)
    function test_deployIdleFunds_capsByIdleBalance(
        uint256 _idle,
        uint256 _request
    ) public {
        _idle = bound(_idle, minFuzzAmount, maxFuzzAmount);
        _request = bound(_request, 1, type(uint256).max);

        // Airdrop idle directly to the strategy (e.g. simulating settled auction proceeds)
        airdrop(asset, address(strategy), _idle);

        uint256 _expected = _idle < _request ? _idle : _request;
        uint256 _lenderAvailable = LENDER.availableDepositLimit(address(strategy));
        if (_lenderAvailable < _expected) _expected = _lenderAvailable;

        vm.prank(management);
        uint256 _deployed = strategy.deployIdleFunds(_request);

        assertEq(_deployed, _expected, "E0");
        assertEq(asset.balanceOf(address(strategy)), _idle - _expected, "E1");
    }

    // 1. seed the strategy with deposits
    // 2. management calls emergencyWithdraw
    // 3. expect all Lender shares drained
    function test_emergencyWithdraw(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        airdrop(asset, user, _amount);

        vm.startPrank(user);
        asset.approve(address(strategy), _amount);
        strategy.deposit(_amount, user);
        vm.stopPrank();

        // Shutdown then emergency withdraw - drains all Lender shares
        vm.prank(management);
        strategy.shutdownStrategy();

        vm.prank(management);
        strategy.emergencyWithdraw(_amount);

        // No more Lender shares; whatever was redeemed atomically lives as idle
        assertEq(LENDER.balanceOf(address(strategy)), 0, "E0");
        assertGt(asset.balanceOf(address(strategy)), 0, "E1");
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 _balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, _balanceBefore + _amount);
    }

    function depositIntoStrategy(IStrategy _strategy, address _user, uint256 _amount) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(IStrategy _strategy, address _user, uint256 _amount) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function openTrove(address _borrower, uint256 _borrowAmount) public returns (uint256 _troveId) {
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        IPriceOracle _oracle = IPriceOracle(_tm.price_oracle());
        ERC20 _collateralToken = ERC20(_tm.collateral_token());

        // Aim for a 10% buffer above MCR
        uint256 _targetCR = _tm.minimum_collateral_ratio() * 110 / 100;
        uint256 _collateralNeeded = (_borrowAmount * _targetCR / ASSET_PRECISION) * 1e36 / _oracle.get_price();

        // Modest interest rate above min
        uint256 _rate = _tm.min_annual_interest_rate() * 10;

        airdrop(_collateralToken, _borrower, _collateralNeeded);

        vm.startPrank(_borrower);
        _collateralToken.approve(address(_tm), _collateralNeeded);
        _troveId = _tm.open_trove(
            block.timestamp, // owner_index
            _collateralNeeded,
            _borrowAmount,
            0, // upper_hint
            0, // lower_hint
            _rate,
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );
        vm.stopPrank();
    }

    function openAndCloseTrove(
        uint256 _holdDuration
    ) public {
        address _borrower = address(77);
        uint256 _borrowAmount = 1_000 * ASSET_PRECISION;

        // Open the trove (interest starts accruing on the borrowed amount)
        uint256 _troveId = openTrove(_borrower, _borrowAmount);

        // Hold the trove open so interest accrues
        skip(_holdDuration);

        // Cover any accrued interest before repaying
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        uint256 _debt = _tm.get_trove_debt_after_interest(_troveId);
        uint256 _balance = asset.balanceOf(_borrower);
        if (_debt > _balance) airdrop(asset, _borrower, _debt - _balance);

        // Repay the trove and return the collateral; the upfront fee plus accrued interest stay with the Lender
        vm.startPrank(_borrower);
        asset.approve(address(_tm), _debt);
        _tm.close_trove(_troveId);
        vm.stopPrank();
    }

    function checkStrategyTotals(
        IStrategy _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public view {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

}
