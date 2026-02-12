// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IDutchDesk {

    // ============================================================================================
    // Structs
    // ============================================================================================

    struct InitializeParams {
        address troveManager;
        address lender;
        address priceOracle;
        address auction;
        address borrowToken;
        address collateralToken;
        uint256 redemptionMinimumPriceBufferPercentage;
        uint256 redemptionStartingPriceBufferPercentage;
        uint256 redemptionReKickStartingPriceBufferPercentage;
        uint256 liquidationMinimumPriceBufferPercentage;
        uint256 liquidationStartingPriceBufferPercentage;
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
    function redemption_minimum_price_buffer_percentage() external view returns (uint256);
    function redemption_starting_price_buffer_percentage() external view returns (uint256);
    function redemption_re_kick_starting_price_buffer_percentage() external view returns (uint256);
    function liquidation_minimum_price_buffer_percentage() external view returns (uint256);
    function liquidation_starting_price_buffer_percentage() external view returns (uint256);

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
        address receiver,
        bool is_liquidation
    ) external;

    function re_kick(
        uint256 auction_id
    ) external;

}
