// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface ILender is IStrategy {

    // ============================================================================================
    // Structs
    // ============================================================================================

    struct WithdrawContext {
        uint32 routeIndex;
        address receiver;
    }

    // ============================================================================================
    // Constants
    // ============================================================================================

    function TROVE_MANAGER() external view returns (address);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function withdrawContext() external view returns (WithdrawContext memory);
    function exchangeRouteIndices(address _lender) external view returns (uint32);

    // ============================================================================================
    // External mutative functions
    // ============================================================================================

    function setExchangeRouteIndex(uint32 _index) external;

}
