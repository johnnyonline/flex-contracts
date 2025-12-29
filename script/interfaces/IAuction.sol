// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IAuction {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function PAPI() external view returns (address);
    function BUY_TOKEN() external view returns (address);
    function BUY_TOKEN_SCALER() external view returns (uint256);
    function SELL_TOKEN() external view returns (address);
    function SELL_TOKEN_SCALER() external view returns (uint256);
    function STEP_DURATION() external view returns (uint256);
    function STEP_DECAY_RATE() external view returns (uint256);
    function AUCTION_LENGTH() external view returns (uint256);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function liquidation_auctions() external view returns (uint256);

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
    function starting_price(
        uint256 auction_id
    ) external view returns (uint256);
    function minimum_price(
        uint256 auction_id
    ) external view returns (uint256);
    function receiver(
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
        uint256 starting_price,
        uint256 minimum_price,
        address receiver,
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
