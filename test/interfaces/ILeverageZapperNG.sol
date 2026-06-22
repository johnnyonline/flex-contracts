// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// NG leverage zapper interface: OpenLeveragedData / LeverUpData gain `taker_funding` + `taker_swap`.
interface ILeverageZapperNG {

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
        uint256 taker_funding;
        SwapData taker_swap;
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
        uint256 taker_funding;
        SwapData taker_swap;
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

    function SWAP_EXECUTOR() external view returns (address);
    function routers(
        address router
    ) external view returns (bool);
    function auction_takers(
        address auction_taker
    ) external view returns (bool);

    function set_router(
        address router,
        bool allowed
    ) external;
    function set_auction_taker(
        address auction_taker,
        bool allowed
    ) external;

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
