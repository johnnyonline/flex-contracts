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

    /// @notice The Daddy
    address public immutable DADDY;

    /// @notice The permissionless Keeper contract for calling `report()` on Lender vaults
    address public constant KEEPER = 0x52605BbF54845f520a3E94792d019f62407db2f8;

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @notice Constructor
    /// @param _daddy The address of the Daddy contract
    constructor(address _daddy) {
        DADDY = _daddy;
    }

    // ============================================================================================
    // Deploy
    // ============================================================================================

    /// @notice Deploy a new Lender contract
    /// @param _asset The address of the borrow token
    /// @param _troveManager The address of the Trove Manager contract
    /// @param _name The name of the vault
    /// @return The address of the newly deployed Lender contract
    function deploy(
        address _asset,
        address _troveManager,
        string calldata _name
    ) external returns (address) {
        // Deploy the Lender contract
        ILender _lender = ILender(address(new Lender(_asset, _troveManager, _name)));

        // Set initial parameters
        _lender.setKeeper(KEEPER);
        _lender.setPendingManagement(DADDY);
        _lender.setPerformanceFeeRecipient(DADDY);

        // Return the address of the new Lender
        return address(_lender);
    }

}
