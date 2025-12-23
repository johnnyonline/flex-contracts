// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IAuction {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function PAPI() external view returns (address);
    function WANT_TOKEN() external view returns (address);
    function WANT_SCALER() external view returns (uint256);
    function FROM_TOKEN() external view returns (address);
    function FROM_SCALER() external view returns (uint256);
    function STEP_DURATION() external view returns (uint256);
    function STEP_DECAY_RATE() external view returns (uint256);
    function VERSION() external pure returns (string memory);

    // ============================================================================================
    // External view functions
    // ============================================================================================

    function get_available(uint256 auction_id) external view returns (uint256);
    function is_active(uint256 auction_id) external view returns (bool);
    function get_kickable(uint256 auction_id) external view returns (uint256);
    function get_amount_needed(uint256 auction_id, uint256 max_amount, uint256 at_timestamp) external view returns (uint256);
    function price(uint256 auction_id, uint256 at_timestamp) external view returns (uint256);

    // ============================================================================================
    // Storage read functions
    // ============================================================================================

    function kicked(uint256 auction_id) external view returns (uint256);
    function initial_amount(uint256 auction_id) external view returns (uint256);
    function current_amount(uint256 auction_id) external view returns (uint256);
    function starting_price(uint256 auction_id) external view returns (uint256);
    function minimum_price(uint256 auction_id) external view returns (uint256);
    function receiver(uint256 auction_id) external view returns (address);

    // ============================================================================================
    // Kick
    // ============================================================================================

    function kick(
        uint256 auction_id,
        uint256 amount_to_kick,
        uint256 starting_price,
        uint256 minimum_price,
        address receiver
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
