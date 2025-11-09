// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {BaseHealthCheck, BaseStrategy, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITroveManager} from "./interfaces/ITroveManager.sol";
import "forge-std/console2.sol";
// @todo -- configurable deposit limit
contract Lender is BaseHealthCheck {

    using SafeERC20 for ERC20;

    // ============================================================================================
    // Events
    // ============================================================================================

    /// @notice Emitted when a user sets their exchange route index
    /// @param user The address of the user
    /// @param index The index of the exchange route set
    event ExchangeRouteIndexSet(address indexed user, uint256 indexed index);

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

    /// @notice Mapping of exchange route indices for a lender
    /// @dev Used to indicate which exchange route to use when redeeming collateral
    mapping(address => uint256) public exchangeRouteIndices; // lender => index

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
    ) BaseHealthCheck(_asset, _name) {
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
        uint256 _index
    ) external {
        exchangeRouteIndices[msg.sender] = _index;
        emit ExchangeRouteIndexSet(msg.sender, _index);
    }

    // ============================================================================================
    // Internal mutative functions
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
        // Get the exchange route index for the caller
        // If none set, defaults to 0
        uint256 _index = exchangeRouteIndices[msg.sender];
        console2.log("Lender: redeeming with exchange route index %s", _index);
        console2.log("caller: %s", msg.sender);
        console2.log("caller1: %s", tx.origin);

        // Try to free `_amount` by selling borrower's collateral
        TROVE_MANAGER.redeem(_amount, _index);
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
