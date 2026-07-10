// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

import {TroveCallbackMock} from "./mocks/TroveCallbackMock.sol";

contract TroveCallbackTests is Base {

    event AddCollateral(uint256 indexed trove_id, address indexed trove_owner, uint256 collateral_amount);

    TroveCallbackMock public mock;

    function setUp() public override {
        Base.setUp();
        mock = new TroveCallbackMock(address(troveManager), address(collateralToken), address(borrowToken));
    }

    function _prep() internal returns (uint256 _collateral, uint256 _debt) {
        _debt = troveManager.min_debt() * 2;
        mintAndDepositIntoLender(userLender, _debt);
        _collateral = (_debt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        airdrop(address(collateralToken), address(mock), _collateral);
    }

    // The callback fires after the loan is delivered but before the collateral is pulled
    function test_openTrove_callbackOrdering() public {
        (uint256 _c, uint256 _d) = _prep();

        uint256 _id = mock.open(_c, _d, DEFAULT_ANNUAL_INTEREST_RATE);

        // Observed inside the callback: loan already delivered, collateral not yet pulled
        assertTrue(mock.callbackFired(), "callback did not fire");
        assertEq(mock.borrowBalDuringCallback(), _d, "loan not delivered before callback");
        assertEq(mock.collateralBalDuringCallback(), _c, "collateral pulled before callback");

        // Final state: trove opened, collateral pulled, loan kept
        ITroveManager.Trove memory _trove = troveManager.troves(_id);
        assertEq(_trove.owner, address(mock), "E0");
        assertEq(_trove.collateral, _c, "E1");
        assertEq(collateralToken.balanceOf(address(mock)), 0, "collateral not pulled");
        assertEq(borrowToken.balanceOf(address(mock)), _d, "loan not kept");
    }

    // A reverting callback unwinds the whole open: no trove, no token movement
    function test_openTrove_callbackRevert_unwinds() public {
        (uint256 _c, uint256 _d) = _prep();
        mock.setRevert(true);

        vm.expectRevert();
        mock.open(_c, _d, DEFAULT_ANNUAL_INTEREST_RATE);

        uint256 _id = uint256(keccak256(abi.encode(address(mock), uint256(0))));
        assertEq(troveManager.troves(_id).owner, address(0), "trove created despite revert");
        assertEq(collateralToken.balanceOf(address(mock)), _c, "collateral moved despite revert");
        assertEq(borrowToken.balanceOf(address(mock)), 0, "loan moved despite revert");
    }

    // An empty callback_data means no callback fires (default behaviour, back-compatible)
    function test_openTrove_noCallbackData_noCallback() public {
        (uint256 _c, uint256 _d) = _prep();
        // Open via the plain path (no callback_data): mock's callback must NOT fire
        airdrop(address(collateralToken), userBorrower, _c);
        vm.startPrank(userBorrower);
        collateralToken.approve(address(troveManager), _c);
        troveManager.open_trove(0, _c, _d, 0, 0, DEFAULT_ANNUAL_INTEREST_RATE, type(uint256).max, 0, 0);
        vm.stopPrank();
        assertFalse(mock.callbackFired(), "callback fired without callback_data");
    }

    // borrow() with collateral_amount adds the collateral (checked against MCR) and pulls it in one call
    function test_borrow_withCollateralAmount() public {
        uint256 _amount = troveManager.min_debt() * 4;
        mintAndDepositIntoLender(userLender, _amount);

        uint256 _collateral = (_amount * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateral, _amount / 2, DEFAULT_ANNUAL_INTEREST_RATE);

        ITroveManager.Trove memory _before = troveManager.troves(_troveId);

        // Borrow more, adding collateral in the same call to keep the ratio healthy
        uint256 _extraDebt = _amount / 4;
        uint256 _extraCollateral =
            (_extraDebt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        airdrop(address(collateralToken), userBorrower, _extraCollateral);

        vm.startPrank(userBorrower);
        collateralToken.approve(address(troveManager), _extraCollateral);
        vm.expectEmit(true, true, false, true, address(troveManager));
        emit AddCollateral(_troveId, userBorrower, _extraCollateral);
        troveManager.borrow(_troveId, _extraDebt, type(uint256).max, 0, 0, _extraCollateral, "");
        vm.stopPrank();

        ITroveManager.Trove memory _after = troveManager.troves(_troveId);
        assertEq(_after.collateral, _before.collateral + _extraCollateral, "collateral not added");
        assertGt(_after.debt, _before.debt, "debt not increased");
    }

    // The MCR check counts the added collateral: a borrow that fails without it succeeds with it
    function test_borrow_collateralAmount_deferredMcrCheck() public {
        uint256 _amount = troveManager.min_debt() * 4;
        mintAndDepositIntoLender(userLender, _amount);

        // Open at the target ratio, sized for the initial debt so there is no headroom to double it
        uint256 _debt = _amount / 2;
        uint256 _collateral = (_debt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();
        uint256 _troveId = mintAndOpenTrove(userBorrower, _collateral, _debt, DEFAULT_ANNUAL_INTEREST_RATE);

        // Doubling the debt breaches MCR unless matching collateral is added
        uint256 _extraDebt = _debt;
        uint256 _extraCollateral =
            (_extraDebt * DEFAULT_TARGET_COLLATERAL_RATIO / BORROW_TOKEN_PRECISION) * ORACLE_PRICE_SCALE / priceOracle.get_price();

        // Without added collateral: reverts on the collateral ratio
        vm.prank(userBorrower);
        vm.expectRevert("!minimum_collateral_ratio");
        troveManager.borrow(_troveId, _extraDebt, type(uint256).max, 0, 0, 0, "");

        // With added collateral: succeeds
        airdrop(address(collateralToken), userBorrower, _extraCollateral);
        vm.startPrank(userBorrower);
        collateralToken.approve(address(troveManager), _extraCollateral);
        troveManager.borrow(_troveId, _extraDebt, type(uint256).max, 0, 0, _extraCollateral, "");
        vm.stopPrank();

        assertEq(troveManager.troves(_troveId).collateral, _collateral + _extraCollateral, "collateral not added");
    }

}
