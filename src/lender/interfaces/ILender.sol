// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface ILender is IStrategy {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function AUCTION() external view returns (address);
    function TROVE_MANAGER() external view returns (address);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function depositLimit() external view returns (uint256);

    // ============================================================================================
    // Management functions
    // ============================================================================================

    function setDepositLimit(
        uint256 _depositLimit
    ) external;

}
