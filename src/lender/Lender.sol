// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {BaseHealthCheck, BaseStrategy, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITroveManager} from "./interfaces/ITroveManager.sol";

contract Lender is BaseHealthCheck {

    using SafeERC20 for ERC20;

    // ============================================================================================
    // Constants
    // ============================================================================================

    ITroveManager public immutable TROVE_MANAGER;

    // ============================================================================================
    // Constructor
    // ============================================================================================

    constructor(
        address _asset,
        address _troveManager,
        string memory _name
    ) BaseHealthCheck(_asset, _name) {
        TROVE_MANAGER = ITroveManager(_troveManager);
        require(TROVE_MANAGER.BORROW_TOKEN() == _asset, "!TROVE_MANAGER");

        // Max approve TroveManager to pull borrow token
        asset.forceApprove(_troveManager, type(uint256).max);
    }

    // ============================================================================================
    // Internal Mutative Functions
    // ============================================================================================

    /// @inheritdoc BaseStrategy
    function _deployFunds(
        uint256 /*_amount*/
    ) internal pure override {
        return;
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(
        uint256 _amount
    ) internal override {
        // Try to free `_amount` by selling borrower's collateral
        TROVE_MANAGER.redeem(_amount);
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        // Total assets is whatever idle asset we have + the latest total debt figure from the trove manager
        _totalAssets = asset.balanceOf(address(this)) + TROVE_MANAGER.sync_total_debt();
    }

}
