// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ICatFactory {

    // ============================================================================================
    // Constants
    // ============================================================================================

    // Contracts
    function TROVE_MANAGER() external view returns (address);
    function SORTED_TROVES() external view returns (address);
    function DUTCH_DESK() external view returns (address);
    function AUCTION() external view returns (address);
    function LENDER_FACTORY() external view returns (address);

    // Default parameters
    function MINIMUM_DEBT() external view returns (uint256);
    function MINIMUM_COLLATERAL_RATIO() external view returns (uint256);
    function UPFRONT_INTEREST_PERIOD() external view returns (uint256);
    function INTEREST_RATE_ADJ_COOLDOWN() external view returns (uint256);
    function MINIMUM_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function STARTING_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE() external view returns (uint256);
    function STEP_DURATION() external view returns (uint256);
    function STEP_DECAY_RATE() external view returns (uint256);
    function AUCTION_LENGTH() external view returns (uint256);

    // Version
    function VERSION() external view returns (string memory);

    // ============================================================================================
    // Deploy
    // ============================================================================================

    function deploy(
        address borrowToken,
        address collateralToken,
        address priceOracle,
        address management,
        address performanceFeeRecipient,
        uint256 minimumDebt,
        uint256 minimumCollateralRatio,
        uint256 upfrontInterestPeriod,
        uint256 interestRateAdjCooldown,
        uint256 minimumPriceBufferPercentage,
        uint256 startingPriceBufferPercentage,
        uint256 emergencyStartingPriceBufferPercentage
    ) external returns (address, address, address, address, address);

}
