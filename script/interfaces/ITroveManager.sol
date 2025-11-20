// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ITroveManager {

    // ============================================================================================
    // Enums
    // ============================================================================================

    // vyper `flags` are n^2
    enum Status {
        none,
        active,
        zombie,
        ignore1,
        closed,
        ignore2,
        ignore3,
        ignore4,
        liquidated
    }

    // ============================================================================================
    // Structs
    // ============================================================================================

    struct Trove {
        uint256 debt;
        uint256 collateral;
        uint256 annual_interest_rate;
        uint64 last_debt_update_time;
        uint64 last_interest_rate_adj_time;
        address owner;
        address pending_owner;
        Status status;
    }

    // ============================================================================================
    // Constants
    // ============================================================================================

    function LENDER() external view returns (address);
    function EXCHANGE() external view returns (address);
    function SORTED_TROVES() external view returns (address);
    function BORROW_TOKEN() external view returns (address);
    function COLLATERAL_TOKEN() external view returns (address);
    function MINIMUM_COLLATERAL_RATIO() external view returns (uint256);
    function MIN_DEBT() external view returns (uint256);
    function MIN_ANNUAL_INTEREST_RATE() external view returns (uint256);
    function MAX_ANNUAL_INTEREST_RATE() external view returns (uint256);
    function UPFRONT_INTEREST_PERIOD() external view returns (uint256);
    function INTEREST_RATE_ADJ_COOLDOWN() external view returns (uint256);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function zombie_trove_id() external view returns (uint256);
    function total_debt() external view returns (uint256);
    function total_weighted_debt() external view returns (uint256);
    function last_debt_update_time() external view returns (uint256);
    function collateral_balance() external view returns (uint256);
    function troves(
        uint256
    ) external view returns (Trove memory);

    // ============================================================================================
    // External view functions
    // ============================================================================================

    function get_upfront_fee(
        uint256 debt_amount,
        uint256 annual_interest_rate
    ) external view returns (uint256);
    function get_trove_debt_after_interest(
        uint256 trove_id
    ) external view returns (uint256);

    // ============================================================================================
    // Sync total debt
    // ============================================================================================

    function sync_total_debt() external returns (uint256);

    // ============================================================================================
    // Ownership
    // ============================================================================================

    function transfer_ownership(
        uint256 trove_id,
        address new_owner
    ) external;
    function accept_ownership(
        uint256 trove_id
    ) external;
    function force_transfer_ownership(
        uint256 trove_id,
        address new_owner
    ) external;

    // ============================================================================================
    // Open trove
    // ============================================================================================

    function open_trove(
        uint256 owner_index,
        uint256 collateral_amount,
        uint256 debt_amount,
        uint256 upper_hint,
        uint256 lower_hint,
        uint256 annual_interest_rate,
        uint256 max_upfront_fee,
        uint256 route_index,
        uint256 min_debt_out
    ) external returns (uint256);

    // ============================================================================================
    // Adjust trove
    // ============================================================================================

    function add_collateral(
        uint256 trove_id,
        uint256 collateral_amount
    ) external;
    function remove_collateral(
        uint256 trove_id,
        uint256 collateral_amount
    ) external;
    function borrow(
        uint256 trove_id,
        uint256 debt_amount,
        uint256 max_upfront_fee,
        uint256 route_index,
        uint256 min_debt_out
    ) external;
    function repay(
        uint256 trove_id,
        uint256 debt_amount
    ) external;
    function adjust_interest_rate(
        uint256 trove_id,
        uint256 new_annual_interest_rate,
        uint256 prev_id,
        uint256 next_id,
        uint256 max_upfront_fee
    ) external;

    // ============================================================================================
    // Close trove
    // ============================================================================================

    function close_trove(
        uint256 trove_id
    ) external;
    function close_zombie_trove(
        uint256 trove_id
    ) external;

    // ============================================================================================
    // Liquidate trove
    // ============================================================================================

    function liquidate_troves(
        uint256[50] calldata trove_ids
    ) external;

    // ============================================================================================
    // Redeem
    // ============================================================================================

    function redeem(
        uint256 amount,
        uint256 route_index
    ) external returns (uint256);

}
