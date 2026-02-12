// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ICatFactory {

    // ============================================================================================
    // Structs
    // ============================================================================================

    struct DeployParams {
        address borrowToken;
        address collateralToken;
        address priceOracle;
        address management;
        address performanceFeeRecipient;
        uint256 minimumDebt;
        uint256 minimumCollateralRatio;
        uint256 upfrontInterestPeriod;
        uint256 interestRateAdjCooldown;
        uint256 minimumPriceBufferPercentage;
        uint256 startingPriceBufferPercentage;
        uint256 emergencyStartingPriceBufferPercentage;
        uint256 stepDuration;
        uint256 stepDecayRate;
        uint256 auctionLength;
    }

    // ============================================================================================
    // Constants
    // ============================================================================================

    // Contracts
    function TROVE_MANAGER() external view returns (address);
    function SORTED_TROVES() external view returns (address);
    function DUTCH_DESK() external view returns (address);
    function AUCTION() external view returns (address);
    function LENDER_FACTORY() external view returns (address);

    // Version
    function VERSION() external view returns (string memory);

    // ============================================================================================
    // Deploy
    // ============================================================================================

    function deploy(
        DeployParams calldata params
    ) external returns (address, address, address, address, address);

}
