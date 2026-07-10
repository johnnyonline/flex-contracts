// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITroveManager} from "../interfaces/ITroveManager.sol";

/// @notice Opens a Trove with a callback, and during the callback (while the Trove Manager holds its
///         reentrancy lock) performs a configurable action to probe the guard.
contract ReentrancyProbe {

    enum Mode {
        REENTER_OPEN, // reenter a @nonreentrant fn -> must revert
        REENTER_REPAY, // reenter a @nonreentrant fn -> must revert
        REENTER_REDEEM, // reenter a @nonreentrant fn -> must revert
        READ_VIEW, // read a view (get_trove_debt_after_interest) -> allowed, views are not locked
        CALL_SYNC_TOTAL_DEBT, // call the undecorated sync fn -> must succeed
        READ_TROVES // read the troves getter -> must succeed
    }

    ITroveManager public immutable TM;
    IERC20 public immutable COLLATERAL;
    Mode public mode;

    constructor(
        address _tm,
        address _collateral
    ) {
        TM = ITroveManager(_tm);
        COLLATERAL = IERC20(_collateral);
    }

    function setMode(
        Mode _mode
    ) external {
        mode = _mode;
    }

    /// @notice Open a Trove routed through the callback so the probe runs mid-lock
    function open(
        uint256 _collateral,
        uint256 _debt,
        uint256 _rate
    ) external returns (uint256) {
        COLLATERAL.approve(address(TM), type(uint256).max);
        return TM.open_trove(0, _collateral, _debt, 0, 0, _rate, type(uint256).max, 0, 0, address(this), abi.encode(uint256(1)));
    }

    function troveCallback(
        uint256 _troveId,
        bytes calldata
    ) external {
        if (mode == Mode.REENTER_OPEN) {
            // Any locked mutable external must revert while the lock is held
            TM.open_trove(1, 1, 1, 0, 0, TM.min_annual_interest_rate(), type(uint256).max, 0, 0);
        } else if (mode == Mode.REENTER_REPAY) {
            TM.repay(_troveId, 1);
        } else if (mode == Mode.REENTER_REDEEM) {
            TM.redeem(1, address(this));
        } else if (mode == Mode.READ_VIEW) {
            TM.get_trove_debt_after_interest(_troveId);
        } else if (mode == Mode.CALL_SYNC_TOTAL_DEBT) {
            TM.sync_total_debt(); // not @nonreentrant, allowed mid-lock
        } else if (mode == Mode.READ_TROVES) {
            TM.troves(_troveId); // getters are not locked, allowed mid-lock
        }
        // Collateral was approved in open(); the Trove Manager pulls it after this callback returns
    }

}
