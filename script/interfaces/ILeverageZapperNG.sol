// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ILeverageZapperNG {

    // ============================================================================================
    // Structs
    // ============================================================================================

    struct SwapData {
        address router;
        bytes data;
    }

    struct OpenLeveragedData {
        address owner;
        address trove_manager;
        address flash_loan_token;
        address auction_taker;
        uint256 owner_index;
        uint256 flash_loan_amount;
        uint256 taker_funding;
        uint256 collateral_amount;
        uint256 debt_amount;
        uint256 prev_id;
        uint256 next_id;
        uint256 annual_interest_rate;
        uint256 max_upfront_fee;
        uint256 min_borrow_out;
        uint256 min_collateral_out;
        SwapData collateral_swap;
        SwapData debt_swap;
        SwapData taker_swap;
    }

    struct LeverUpData {
        address trove_manager;
        address flash_loan_token;
        address auction_taker;
        uint256 trove_id;
        uint256 flash_loan_amount;
        uint256 taker_funding;
        uint256 collateral_amount;
        uint256 debt_amount;
        uint256 max_upfront_fee;
        uint256 min_borrow_out;
        uint256 min_collateral_out;
        SwapData collateral_swap;
        SwapData debt_swap;
        SwapData taker_swap;
    }

    // ============================================================================================
    // Whitelist
    // ============================================================================================

    function set_router(
        address router,
        bool allowed
    ) external;
    function set_auction_taker(
        address auction_taker,
        bool allowed
    ) external;

    // ============================================================================================
    // External functions
    // ============================================================================================

    function open_leveraged_trove(
        OpenLeveragedData calldata data
    ) external returns (uint256);
    function lever_up_trove(
        LeverUpData calldata data
    ) external;

}
