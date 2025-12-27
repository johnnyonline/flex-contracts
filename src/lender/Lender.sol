// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseHooks, ERC20} from "@periphery/Bases/Hooks/BaseHooks.sol";
import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";

import {IAuction} from "./interfaces/IAuction.sol";
import {ITroveManager} from "./interfaces/ITroveManager.sol";

contract Lender is BaseHooks {

    using SafeERC20 for ERC20;

    // ============================================================================================
    // Events
    // ============================================================================================

    /// @notice Emitted when the deposit limit is set
    /// @param depositLimit The new deposit limit
    event DepositLimitSet(uint256 depositLimit);

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice Auction contract
    IAuction public immutable AUCTION;

    /// @notice TroveManager contract
    ITroveManager public immutable TROVE_MANAGER;

    // ============================================================================================
    // Storage
    // ============================================================================================

    /// @notice The receiver of auction proceeds
    address private _auctionProceedsReceiver;

    /// @notice The strategy deposit limit
    /// @dev Initialized to `type(uint256).max` (no limit) in constructor
    uint256 public depositLimit;

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @notice Constructor
    /// @param _asset The address of the borrow token
    /// @param _auction The address of the Auction contract
    /// @param _troveManager The address of the TroveManager contract
    /// @param _name The name of the vault
    constructor(
        address _asset,
        address _auction,
        address _troveManager,
        string memory _name
    ) BaseHooks(_asset, _name) {
        // Set immutable addresses
        AUCTION = IAuction(_auction);
        TROVE_MANAGER = ITroveManager(_troveManager);

        // No deposit limit by default
        depositLimit = type(uint256).max;

        // Max approve TroveManager to pull borrow token
        asset.forceApprove(_troveManager, type(uint256).max);
    }

    // ============================================================================================
    // Public view function
    // ============================================================================================

    // @inheritdoc BaseStrategy
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        uint256 _depositLimit = depositLimit;
        uint256 _currentAssets = TokenizedStrategy.totalAssets();
        return _depositLimit <= _currentAssets ? 0 : _depositLimit - _currentAssets;
    }

    // @inheritdoc BaseStrategy
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        // If the strategy is shutdown always allow full withdrawals
        if (TokenizedStrategy.isShutdown()) return type(uint256).max;

        // Redemptions are blocked during ongoing liquidation auctions.
        // During liquidation, collateral has been seized but not yet sold for borrow tokens.
        // The system is temporarily insolvent until the auction completes and proceeds return to this contract.
        // However, any idle liquidity already in the contract remains available for withdrawal
        return AUCTION.is_ongoing_liquidation_auction() ? asset.balanceOf(address(this)) : type(uint256).max;
    }

    // ============================================================================================
    // Management functions
    // ============================================================================================

    /// @notice Set the strategy deposit limit
    /// @dev Only callable by management
    /// @param _depositLimit The new deposit limit
    function setDepositLimit(uint256 _depositLimit) external onlyManagement {
        depositLimit = _depositLimit;
        emit DepositLimitSet(_depositLimit);
    }

    // ============================================================================================
    // Internal mutative functions
    // ============================================================================================

    /// @notice Hook called before the TokenizedStrategy's withdraw/redeem
    /// @dev Sets the receiver of auction proceeds to the withdraw/redeem receiver
    function _preWithdrawHook(
        uint256 /*_assets*/,
        uint256 /*_shares*/,
        address _receiver,
        address /*_owner*/,
        uint256 /*_maxLoss*/
    ) internal override {
        // Set the receiver of auction proceeds
        _auctionProceedsReceiver = _receiver;
    }

    /// @inheritdoc BaseStrategy
    function _deployFunds(uint256 /*_amount*/) internal pure override {
        return;
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(uint256 _amount) internal override {
        // Try to free `_amount` by auctioning collateral for borrow tokens
        // Auction proceeds will be sent to `_auctionProceedsReceiver` which is set in the `_preWithdrawHook`
        TROVE_MANAGER.redeem(_amount, _auctionProceedsReceiver);
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal override returns (uint256 /*_totalAssets*/) {
        // Total assets is whatever idle asset we have + the latest total debt figure from the trove manager
        return asset.balanceOf(address(this)) + TROVE_MANAGER.sync_total_debt();
    }

}
