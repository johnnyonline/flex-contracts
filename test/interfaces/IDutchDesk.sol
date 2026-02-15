// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IDutchDesk {

    // ============================================================================================
    // Structs
    // ============================================================================================

    struct InitializeParams {
        address trove_manager;
        address lender;
        address price_oracle;
        address auction;
        address borrow_token;
        address collateral_token;
        uint256 minimum_price_buffer_percentage;
        uint256 starting_price_buffer_percentage;
        uint256 re_kick_starting_price_buffer_percentage;
    }

    // ============================================================================================
    // Storage
    // ============================================================================================

    // Contracts
    function trove_manager() external view returns (address);
    function lender() external view returns (address);
    function price_oracle() external view returns (address);
    function auction() external view returns (address);

    // Collateral token
    function collateral_token() external view returns (address);

    // Parameters
    function collateral_token_precision() external view returns (uint256);
    function minimum_price_buffer_percentage() external view returns (uint256);
    function starting_price_buffer_percentage() external view returns (uint256);
    function re_kick_starting_price_buffer_percentage() external view returns (uint256);

    // Accounting
    function nonce() external view returns (uint256);

    // ============================================================================================
    // Initialize
    // ============================================================================================

    function initialize(
        InitializeParams calldata params
    ) external;

    // ============================================================================================
    // Kick
    // ============================================================================================

    function kick(
        uint256 kick_amount,
        uint256 maximum_amount,
        address receiver
    ) external;

    function re_kick(
        uint256 auction_id
    ) external;

}
