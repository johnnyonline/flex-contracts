// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import {ILender} from "./interfaces/ILender.sol";

import {Lender} from "./Lender.sol";

/// @title Lender Factory
/// @author Flex
/// @notice Factory contract for deploying new Lender vaults
contract LenderFactory {

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice The permissionless Keeper contract for calling `report()` on Lender vaults
    address public constant KEEPER = 0x52605BbF54845f520a3E94792d019f62407db2f8;

    // ============================================================================================
    // Deploy
    // ============================================================================================

    /// @notice Deploy a new Lender contract
    /// @param _asset The address of the borrow token
    /// @param _troveManager The address of the Trove Manager contract
    /// @param _management The address of the management
    /// @param _performanceFeeRecipient The address of the performance fee recipient
    /// @param _name The name of the vault
    /// @return The address of the newly deployed Lender contract
    function deploy(
        address _asset,
        address _troveManager,
        address _management,
        address _performanceFeeRecipient,
        string calldata _name
    ) external returns (address) {
        // Deploy the Lender contract
        ILender _lender = ILender(address(new Lender(_asset, _troveManager, _name)));

        // Set initial parameters
        _lender.setKeeper(KEEPER);
        _lender.setPendingManagement(_management);
        _lender.setPerformanceFeeRecipient(_performanceFeeRecipient);

        // Return the address of the new Lender
        return address(_lender);
    }

}
