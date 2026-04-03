// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ILeverageZapper {

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
    }

    struct CloseLeveragedData {
        address trove_manager;
        address flash_loan_token;
        uint256 trove_id;
        uint256 flash_loan_amount;
        SwapData collateral_swap;
        SwapData debt_swap;
    }

    struct LeverUpData {
        address trove_manager;
        address flash_loan_token;
        address auction_taker;
        uint256 trove_id;
        uint256 flash_loan_amount;
        uint256 collateral_amount;
        uint256 debt_amount;
        uint256 max_upfront_fee;
        uint256 min_borrow_out;
        uint256 min_collateral_out;
        SwapData collateral_swap;
        SwapData debt_swap;
    }

    struct LeverDownData {
        address trove_manager;
        address flash_loan_token;
        uint256 trove_id;
        uint256 flash_loan_amount;
        uint256 collateral_to_remove;
        SwapData collateral_swap;
        SwapData debt_swap;
    }

    // ============================================================================================
    // External functions
    // ============================================================================================

    function open_leveraged_trove(
        OpenLeveragedData calldata data
    ) external returns (uint256);
    function close_leveraged_trove(
        CloseLeveragedData calldata data
    ) external;
    function lever_up_trove(
        LeverUpData calldata data
    ) external;
    function lever_down_trove(
        LeverDownData calldata data
    ) external;

}
