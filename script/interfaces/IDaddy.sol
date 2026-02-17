// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IDaddy {

    // ============================================================================================
    // Storage
    // ============================================================================================

    function owner() external view returns (address);
    function pending_owner() external view returns (address);

    // ============================================================================================
    // Execute
    // ============================================================================================

    function execute(
        address target,
        bytes calldata data,
        uint256 eth_value,
        bool revert_on_failure
    ) external payable returns (bytes memory);

    // ============================================================================================
    // Ownership
    // ============================================================================================

    function transfer_ownership(
        address new_owner
    ) external;
    function accept_ownership() external;

}
