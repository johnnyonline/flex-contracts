// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IRegistry {

    // ============================================================================================
    // Enums
    // ============================================================================================

    // vyper `flags` are 2^n, but with only 2 flags this maps to 0, 1, 2
    enum Status {
        empty, // 0 - default/unset
        endorsed, // 1 - ENDORSED flag
        unendorsed // 2 - UNENDORSED flag
    }

    // ============================================================================================
    // Constants
    // ============================================================================================

    function VERSION() external view returns (string memory);

    // ============================================================================================
    // Storage
    // ============================================================================================

    // Ownership
    function daddy() external view returns (address);
    function pending_daddy() external view returns (address);

    // Markets
    function markets(
        uint256 index
    ) external view returns (address);
    function market_status(
        address trove_manager
    ) external view returns (Status);

    // ============================================================================================
    // View functions
    // ============================================================================================

    function markets_count() external view returns (uint256);
    function markets_count_for_pair(
        address collateral_token,
        address borrow_token
    ) external view returns (uint256);
    function find_market_for_pair(
        address collateral_token,
        address borrow_token,
        uint256 index
    ) external view returns (address);

    // ============================================================================================
    // Ownership
    // ============================================================================================

    function transfer_ownership(
        address new_daddy
    ) external;
    function accept_ownership() external;

    // ============================================================================================
    // Endorse
    // ============================================================================================

    function endorse(
        address trove_manager
    ) external;
    function unendorse(
        address trove_manager
    ) external;

}
