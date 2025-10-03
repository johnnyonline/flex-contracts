// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IExchange {

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    function BORROW_TOKEN() external view returns (address);
    function COLLATERAL_TOKEN() external view returns (address);
    function price() external view returns (uint256);

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    function swap(uint256 amount, address receiver) external returns (uint256);
}