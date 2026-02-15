// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface ILender is IStrategy {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function TROVE_MANAGER() external view returns (address);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function depositLimit() external view returns (uint256);

    // ============================================================================================
    // Management functions
    // ============================================================================================

    function setKeeper(
        address _keeper
    ) external;

    function setPendingManagement(
        address _management
    ) external;

    function setPerformanceFeeRecipient(
        address _performanceFeeRecipient
    ) external;

    function setDepositLimit(
        uint256 _depositLimit
    ) external;

}
