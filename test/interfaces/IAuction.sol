// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IAuction {

    // ============================================================================================
    // Structs
    // ============================================================================================

    struct InitializeParams {
        address papi;
        address buyToken;
        address sellToken;
        uint256 stepDuration;
        uint256 stepDecayRate;
        uint256 auctionLength;
    }

    // ============================================================================================
    // Storage
    // ============================================================================================

    // Papi
    function papi() external view returns (address);

    // Tokens
    function buy_token() external view returns (address);
    function buy_token_scaler() external view returns (uint256);
    function sell_token() external view returns (address);
    function sell_token_scaler() external view returns (uint256);

    // Parameters
    function step_duration() external view returns (uint256);
    function step_decay_rate() external view returns (uint256);
    function auction_length() external view returns (uint256);

    // Accounting
    function liquidation_auctions() external view returns (uint256);

    // ============================================================================================
    // Initialize
    // ============================================================================================

    function initialize(
        InitializeParams calldata params
    ) external;

    // ============================================================================================
    // External view functions
    // ============================================================================================

    function get_available_amount(
        uint256 auction_id
    ) external view returns (uint256);
    function get_kickable_amount(
        uint256 auction_id
    ) external view returns (uint256);
    function get_needed_amount(
        uint256 auction_id,
        uint256 max_amount,
        uint256 at_timestamp
    ) external view returns (uint256);
    function get_price(
        uint256 auction_id,
        uint256 at_timestamp
    ) external view returns (uint256);
    function is_active(
        uint256 auction_id
    ) external view returns (bool);
    function is_ongoing_liquidation_auction() external view returns (bool);

    // ============================================================================================
    // Storage read functions
    // ============================================================================================

    function kick_timestamp(
        uint256 auction_id
    ) external view returns (uint256);
    function initial_amount(
        uint256 auction_id
    ) external view returns (uint256);
    function current_amount(
        uint256 auction_id
    ) external view returns (uint256);
    function maximum_amount(
        uint256 auction_id
    ) external view returns (uint256);
    function amount_received(
        uint256 auction_id
    ) external view returns (uint256);
    function starting_price(
        uint256 auction_id
    ) external view returns (uint256);
    function minimum_price(
        uint256 auction_id
    ) external view returns (uint256);
    function receiver(
        uint256 auction_id
    ) external view returns (address);
    function surplus_receiver(
        uint256 auction_id
    ) external view returns (address);
    function is_liquidation(
        uint256 auction_id
    ) external view returns (bool);

    // ============================================================================================
    // Kick
    // ============================================================================================

    function kick(
        uint256 auction_id,
        uint256 kick_amount,
        uint256 maximum_amount,
        uint256 starting_price,
        uint256 minimum_price,
        address receiver,
        address surplus_receiver,
        bool is_liquidation
    ) external;

    function re_kick(
        uint256 auction_id,
        uint256 starting_price,
        uint256 minimum_price
    ) external;

    // ============================================================================================
    // External mutative functions
    // ============================================================================================

    function take(
        uint256 auction_id,
        uint256 max_amount,
        address receiver,
        bytes calldata data
    ) external returns (uint256);

}
