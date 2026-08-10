// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

import {ReentrancyProbe} from "./mocks/ReentrancyProbe.sol";

contract TroveManagerReentrancyTests is Base {

    ReentrancyProbe public probe;

    function setUp() public override {
        Base.setUp();
        probe = new ReentrancyProbe(address(troveManager), address(collateralToken));
    }

    // Fund the lender with idle (so the loan is a plain transfer, no redemption) and give the probe collateral
    function _prep() internal returns (uint256 _collateral, uint256 _debt) {
        _debt = troveManager.min_debt() * 2;
        mintAndDepositIntoLender(userLender, _debt);
        _collateral = (_debt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        airdrop(address(collateralToken), address(probe), _collateral);
    }

    // Reentering a locked mutable external from inside the callback must revert (whole tx unwinds)
    function test_reentry_openTrove_reverts() public {
        (uint256 _c, uint256 _d) = _prep();
        probe.setMode(ReentrancyProbe.Mode.REENTER_OPEN);
        vm.expectRevert();
        probe.open(_c, _d, DEFAULT_ANNUAL_INTEREST_RATE);
    }

    function test_reentry_repay_reverts() public {
        (uint256 _c, uint256 _d) = _prep();
        probe.setMode(ReentrancyProbe.Mode.REENTER_REPAY);
        vm.expectRevert();
        probe.open(_c, _d, DEFAULT_ANNUAL_INTEREST_RATE);
    }

    // Views are not locked, so reading one mid-lock is allowed (e.g. by an integrator's callback)
    function test_reentry_readView_allowed() public {
        (uint256 _c, uint256 _d) = _prep();
        probe.setMode(ReentrancyProbe.Mode.READ_VIEW);
        uint256 _id = probe.open(_c, _d, DEFAULT_ANNUAL_INTEREST_RATE);
        assertEq(troveManager.troves(_id).owner, address(probe), "trove not opened");
    }

    // sync_total_debt is not @nonreentrant, so it must be callable mid-lock (the Lender's report path relies on this)
    function test_reentry_syncTotalDebt_allowed() public {
        (uint256 _c, uint256 _d) = _prep();
        probe.setMode(ReentrancyProbe.Mode.CALL_SYNC_TOTAL_DEBT);
        uint256 _id = probe.open(_c, _d, DEFAULT_ANNUAL_INTEREST_RATE);
        assertEq(troveManager.troves(_id).owner, address(probe), "trove not opened");
    }

    // Getters are not locked, so the troves getter must be readable mid-lock (Sorted Troves relies on this)
    function test_reentry_readTroves_allowed() public {
        (uint256 _c, uint256 _d) = _prep();
        probe.setMode(ReentrancyProbe.Mode.READ_TROVES);
        uint256 _id = probe.open(_c, _d, DEFAULT_ANNUAL_INTEREST_RATE);
        assertEq(troveManager.troves(_id).owner, address(probe), "trove not opened");
    }

}
