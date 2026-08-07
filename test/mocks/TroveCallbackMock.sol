// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITroveManager} from "../interfaces/ITroveManager.sol";

/// @notice Opens a Trove through the callback, recording balances observed mid-callback so tests can
///         assert the loan-then-callback-then-collateral-pull ordering. Can revert to test atomicity.
contract TroveCallbackMock {

    ITroveManager public immutable TM;
    IERC20 public immutable COLLATERAL;
    IERC20 public immutable BORROW;

    bool public revertInCallback;
    bool public callbackFired;
    uint256 public borrowBalDuringCallback;
    uint256 public collateralBalDuringCallback;

    constructor(
        address _tm,
        address _collateral,
        address _borrow
    ) {
        TM = ITroveManager(_tm);
        COLLATERAL = IERC20(_collateral);
        BORROW = IERC20(_borrow);
    }

    function setRevert(
        bool _revert
    ) external {
        revertInCallback = _revert;
    }

    function open(
        uint256 _collateral,
        uint256 _debt,
        uint256 _rate
    ) external returns (uint256) {
        COLLATERAL.approve(address(TM), type(uint256).max);
        return TM.open_trove(0, _collateral, _debt, 0, 0, _rate, type(uint256).max, 0, 0, address(this), abi.encode(uint256(1)));
    }

    function troveCallback(
        uint256,
        bytes calldata
    ) external {
        callbackFired = true;
        borrowBalDuringCallback = BORROW.balanceOf(address(this)); // loan should already be delivered
        collateralBalDuringCallback = COLLATERAL.balanceOf(address(this)); // collateral should not be pulled yet
        if (revertInCallback) revert("callback revert");
        // Collateral was approved in open(); the Trove Manager pulls it after this callback returns
    }

}
