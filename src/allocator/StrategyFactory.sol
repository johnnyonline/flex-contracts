// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import {IStrategy} from "./interfaces/IStrategy.sol";

import {FlexLenderStrategy as Strategy} from "./Strategy.sol";

/// @title Strategy Factory
/// @author Flex
/// @notice Deploys new Flex Lender Strategy vaults
contract StrategyFactory {

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice The permissionless Keeper contract for calling `report()` on Strategy vaults
    address public constant KEEPER = 0x52605BbF54845f520a3E94792d019f62407db2f8;

    // ============================================================================================
    // Deploy
    // ============================================================================================

    /// @notice Deploy a new Flex Lender Strategy contract
    /// @param _asset The address of the borrow token
    /// @param _lender The address of the Lender contract
    /// @param _management The address of the Strategy management
    /// @param _performanceFeeRecipient The address that receives performance fees from the Strategy
    /// @param _name The name of the strategy
    /// @return The address of the newly deployed Strategy contract
    function deploy(
        address _asset,
        address _lender,
        address _management,
        address _performanceFeeRecipient,
        string calldata _name
    ) external returns (address) {
        // Deploy the Strategy contract
        IStrategy _strategy = IStrategy(address(new Strategy(_asset, _lender, _name)));

        // Configure Strategy roles
        _strategy.setKeeper(KEEPER);
        _strategy.setPendingManagement(_management);
        _strategy.setPerformanceFeeRecipient(_performanceFeeRecipient);

        // Return the address of the new Strategy
        return address(_strategy);
    }

}
