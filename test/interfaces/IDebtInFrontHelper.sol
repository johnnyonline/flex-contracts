// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IDebtInFrontHelper {

    // ============================================================================================
    // Storage
    // ============================================================================================

    function TROVE_MANAGER() external view returns (address);
    function SORTED_TROVES() external view returns (address);

    // ============================================================================================
    // View functions
    // ============================================================================================

    function get_debt_in_front(
        uint256 interest_rate_low,
        uint256 interest_rate_high,
        uint256 stop_at_trove_id,
        uint256 hint_prev_id,
        uint256 hint_next_id
    ) external view returns (uint256);

}
