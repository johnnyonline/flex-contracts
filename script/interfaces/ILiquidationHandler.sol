// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ILiquidationHandler {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function LENDER() external view returns (address);
    function TROVE_MANAGER() external view returns (address);
    function AUCTION() external view returns (address);
    function PRICE_ORACLE() external view returns (address);
    function AUCTION_FACTORY() external view returns (address);
    function BORROW_TOKEN() external view returns (address);
    function COLLATERAL_TOKEN() external view returns (address);
    function DUST_THRESHOLD() external view returns (uint256);
    function MAX_AUCTION_AMOUNT() external view returns (uint256);
    function STARTING_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function MINIMUM_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function MAX_GAS_PRICE_TO_TRIGGER() external view returns (uint256);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function owner() external view returns (address);
    function pending_owner() external view returns (address);
    function use_auction() external view returns (bool);
    function keeper() external view returns (address);

    // ============================================================================================
    // View functions
    // ============================================================================================

    function kick_trigger() external view returns (bool);

    // ============================================================================================
    // Keeper functions
    // ============================================================================================

    function kick() external;

    // ============================================================================================
    // Owner functions
    // ============================================================================================

    function transfer_ownership(
        address new_owner
    ) external;
    function accept_ownership() external;
    function toggle_use_auction() external;
    function set_keeper(
        address new_keeper
    ) external;

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    function process(
        uint256 collateral_amount,
        uint256 debt_amount,
        address liquidator
    ) external;

}
