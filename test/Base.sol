// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import "../script/Deploy.s.sol";

import "forge-std/Test.sol";

abstract contract Base is Deploy, Test {

    address public userLender = address(420);
    address public userBorrower = address(69);
    address public anotherUserBorrower = address(555);

    // Fuzz lend amount from 0.001 of 1e18 coin up to 1 million of a 1e18 coin
    uint256 public maxFuzzAmount = 1_000_000 ether;
    uint256 public minFuzzAmount = 0.001 ether;

    function setUp() public virtual {
        // notify deplyment script that this is a test
        isTest = true;

        // create fork
        uint256 _blockNumber = 23_513_850; // cache state for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        // deploy and initialize contracts
        run();

        // Set up Lender
        vm.prank(management);
        lender.acceptManagement();
    }

    function airdrop(
        address _token,
        address _to,
        uint256 _amount
    ) public {
        _token == address(0) ? vm.deal(_to, _amount) : deal({token: _token, to: _to, give: _amount});
    }

    function depositIntoLender(address _user, uint256 _amount) public {
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
        return _mintAndOpenTrove(_user, _collateralAmount, _borrowAmount, _annualInterestRate, false);
    }

    function mintAndOpenTrove_revertOnMinDebt(
        address _user,
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        uint256 _annualInterestRate
    ) public returns (uint256 _troveId) {
        _mintAndOpenTrove(_user, _collateralAmount, _borrowAmount, _annualInterestRate, true);
    }

    function _mintAndOpenTrove(
        address _user,
        uint256 _collateralAmount,
        uint256 _borrowAmount,
        uint256 _annualInterestRate,
        bool _shouldRevert
    ) internal returns (uint256 _troveId) {
        // Airdrop some collateral to borrower
        airdrop(address(collateralToken), _user, _collateralAmount);

        // Open a trove
        vm.startPrank(_user);
        collateralToken.approve(address(troveManager), _collateralAmount);
        if (_shouldRevert) vm.expectRevert("!trove_new_debt");
        _troveId = troveManager.open_trove(
            block.timestamp, // index
            _collateralAmount, // collateral_amount
            _borrowAmount, // debt_amount
            0, // upper_hint
            0, // lower_hint
            _annualInterestRate, // annual_interest_rate
            type(uint256).max, // max_upfront_fee
            0 // min_debt_out
        );
        vm.stopPrank();
    }

}
