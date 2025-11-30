// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IExchangeRoute} from "./IExchangeRoute.sol";

interface IDutchExchangeRoute is IExchangeRoute {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function EXCHANGE_HANDLER() external view returns (address);
    function PRICE_ORACLE() external view returns (address);
    function AUCTION_FACTORY() external view returns (address);
    function BORROW_TOKEN() external view returns (address);
    function COLLATERAL_TOKEN() external view returns (address);
    function DUST_THRESHOLD() external view returns (uint256);
    function MAX_AUCTION_AMOUNT() external view returns (uint256);
    function MIN_AUCTION_AMOUNT() external view returns (uint256);
    function STARTING_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function MINIMUM_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function MAX_GAS_PRICE_TO_TRIGGER() external view returns (uint256);
    function MAX_AUCTIONS() external view returns (uint256);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function owner() external view returns (address);
    function pending_owner() external view returns (address);
    function keeper() external view returns (address);
    function auctions(
        uint256 index
    ) external view returns (address);

    // ============================================================================================
    // View functions
    // ============================================================================================

    function kick_trigger() external view returns (address[] memory);

    // ============================================================================================
    // Keeper functions
    // ============================================================================================

    function kick(
        address[] memory
    ) external;

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

}
