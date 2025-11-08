// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IExchange {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function BORROW_TOKEN() external view returns (address);
    function COLLATERAL_TOKEN() external view returns (address);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function owner() external view returns (address);
    function pending_owner() external view returns (address);
    function route_index() external view returns (uint256);
    function routes(
        uint256
    ) external view returns (address);

    // ============================================================================================
    // Owner functions
    // ============================================================================================

    function transfer_ownership(
        address new_owner
    ) external;
    function accept_ownership() external;
    function add_route(
        address route
    ) external;

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    function swap(
        uint256 amount,
        uint256 index,
        address receiver
    ) external returns (uint256);

}
