// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IExchangeRoute {

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    function execute(
        uint256 amount,
        address receiver
    ) external returns (uint256);

}
