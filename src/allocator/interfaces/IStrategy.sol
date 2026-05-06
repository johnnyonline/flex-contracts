// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

import {ILender} from "../../lender/interfaces/ILender.sol";

interface IStrategy is IBaseHealthCheck {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function LENDER() external view returns (ILender);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function openDeposits() external view returns (bool);

    function allowed(
        address _owner
    ) external view returns (bool);

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

    function forceFreeFunds(
        uint256 _amount
    ) external returns (uint256);

    function deployIdleFunds(
        uint256 _amount
    ) external returns (uint256);

    function setOpen(
        bool _isOpen
    ) external;

    function setAllowed(
        address _address,
        bool _isAllowed
    ) external;

}
