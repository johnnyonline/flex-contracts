// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {BaseHooks, ERC20} from "@periphery/Bases/Hooks/BaseHooks.sol";
import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITroveManager} from "./interfaces/ITroveManager.sol";
import "forge-std/console2.sol";
// @todo -- configurable deposit limit
contract Lender is BaseHooks {

    using SafeERC20 for ERC20;

    // ============================================================================================
    // Events
    // ============================================================================================

    /// @notice Emitted when a user sets their exchange route index
    /// @param user The address of the user
    /// @param index The index of the exchange route set
    event ExchangeRouteIndexSet(address indexed user, uint256 indexed index);

    // ============================================================================================
    // Structs
    // ============================================================================================

    /// @notice Per-withdrawal context used when freeing funds
    /// @dev Populated in `_preWithdrawHook` and cleared in `_postWithdrawHook`
    ///      Used by `_freeFunds()` and the trove_manager to know which exchange route
    ///      and potentially receiver to use for the current withdrawal
    struct WithdrawContext {
        uint32 routeIndex;
        address receiver;
    }

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice Deposit limit for the unaudited launch
    /// @dev Should be removed after audit
    uint256 public constant DEPOSIT_LIMIT = 10_000 * 1e18;

    /// @notice TroveManager contract
    ITroveManager public immutable TROVE_MANAGER;

    // ============================================================================================
    // Storage
    // ============================================================================================

    /// @notice Holds per-withdrawal settings (exchange route + receiver)
    /// @dev Set in `_preWithdrawHook` and deleted in `_postWithdrawHook`
    ///      Used by `_freeFunds()` (and downstream trove_manager and exchange) to know
    ///      which exchange route to use and potentially where redeemed tokens should be sent
    WithdrawContext public withdrawContext;

    /// @notice Mapping of exchange route indices for a lender
    /// @dev Used to indicate which exchange route to use when redeeming collateral
    mapping(address => uint32) public exchangeRouteIndices; // lender --> index

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @notice Constructor
    /// @param _asset The address of the borrow token
    /// @param _troveManager The address of the TroveManager contract
    /// @param _name The name of the vault
    constructor(
        address _asset,
        address _troveManager,
        string memory _name
    ) BaseHooks(_asset, _name) {
        TROVE_MANAGER = ITroveManager(_troveManager);
        require(TROVE_MANAGER.BORROW_TOKEN() == _asset, "!TROVE_MANAGER");

        // Max approve TroveManager to pull borrow token
        asset.forceApprove(_troveManager, type(uint256).max);
    }

    // ============================================================================================
    // Public view function
    // ============================================================================================

    // @inheritdoc BaseStrategy
    function availableDepositLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        uint256 _currentAssets = TokenizedStrategy.totalAssets();
        return DEPOSIT_LIMIT <= _currentAssets ? 0 : DEPOSIT_LIMIT - _currentAssets;
    }

    // ============================================================================================
    // External mutative functions
    // ============================================================================================

    /// @notice Set the exchange route index for the caller
    /// @param _index The index of the exchange route to use
    function setExchangeRouteIndex(
        uint32 _index
    ) external {
        exchangeRouteIndices[msg.sender] = _index;
        emit ExchangeRouteIndexSet(msg.sender, _index);
    }

    // ============================================================================================
    // Internal mutative functions
    // ============================================================================================

    /// @notice Hook called before the TokenizedStrategy's withdraw/redeem
    /// @dev Loads the caller's configured exchange route index and receiver
    ///      into `withdrawContext` so that `_freeFunds()` and the trove_manager
    ///      know how to process this withdrawal
    function _preWithdrawHook(
        uint256 /*_assets*/,
        uint256 /*_shares*/,
        address _receiver,
        address _owner,
        uint256 /*_maxLoss*/
    ) internal override {
        // Set the route index and receiver for this withdrawal
        withdrawContext = WithdrawContext({
            routeIndex: exchangeRouteIndices[_owner],
            receiver: _receiver
        });
    }

    /// @notice Hook called after the TokenizedStrategy's withdraw/redeem
    /// @dev Clears the temporary `exchangeRouteIndex` variable
    function _postWithdrawHook(
        uint256 /*_assets*/,
        uint256 /*_shares*/,
        address /*_receiver*/,
        address /*_owner*/,
        uint256 /*_maxLoss*/
    ) internal override {
        // Reset the withdrawal context
        delete withdrawContext;
    }

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
        // Try to free `_amount` by selling borrower's collateral through the
        // currently-selected exchange route (set in `_preWithdrawHook`)
        TROVE_MANAGER.redeem(_amount, withdrawContext.routeIndex);
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport()
        internal
        override
        returns (
            uint256 /*_totalAssets*/
        )
    {
        // Total assets is whatever idle asset we have + the latest total debt figure from the trove manager
        return asset.balanceOf(address(this)) + TROVE_MANAGER.sync_total_debt();
    }

}
