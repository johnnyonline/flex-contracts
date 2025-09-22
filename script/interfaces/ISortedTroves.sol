// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ISortedTroves {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function BORROWER() external view returns (address);

    // ============================================================================================
    // View functions
    // ============================================================================================

    function empty() external view returns (bool);
    function size() external view returns (uint256);
    function first() external view returns (uint256);
    function last() external view returns (uint256);
    function next(
        uint256 id
    ) external view returns (uint256);
    function prev(
        uint256 id
    ) external view returns (uint256);
    function contains(
        uint256 id
    ) external view returns (bool);
    function valid_insert_position(
        uint256 annual_interest_rate,
        uint256 prev_id,
        uint256 next_id
    ) external view returns (bool);
    function find_insert_position(
        uint256 annual_interest_rate,
        uint256 prev_id,
        uint256 next_id
    ) external view returns (uint256, uint256);

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    function insert(uint256 id, uint256 annual_interest_rate, uint256 prev_id, uint256 next_id) external;
    function remove(
        uint256 id
    ) external;
    function re_insert(uint256 id, uint256 new_annual_interest_rate, uint256 prev_id, uint256 next_id) external;

}
