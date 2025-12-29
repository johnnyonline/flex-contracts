// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IDutchDesk {

    // ============================================================================================
    // Constants
    // ============================================================================================

    // Contracts
    function TROVE_MANAGER() external view returns (address);
    function PRICE_ORACLE() external view returns (address);
    function AUCTION() external view returns (address);

    // Tokens
    function BORROW_TOKEN() external view returns (address);
    function COLLATERAL_TOKEN() external view returns (address);

    // Parameters
    function MINIMUM_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function STARTING_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function nonce() external view returns (uint256);

    // ============================================================================================
    // Kick
    // ============================================================================================

    function kick(
        uint256 kick_amount,
        address receiver,
        bool is_liquidation
    ) external;

    function re_kick(
        uint256 auction_id
    ) external;

}
