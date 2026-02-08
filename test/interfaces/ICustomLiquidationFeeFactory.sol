// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ICustomLiquidationFeeFactory {

    function deploy(
        address borrow_token,
        address collateral_token,
        address price_oracle,
        address management,
        address performance_fee_recipient,
        uint256 minimum_debt,
        uint256 minimum_collateral_ratio,
        uint256 upfront_interest_period,
        uint256 interest_rate_adj_cooldown,
        uint256 liquidator_fee_percentage
    ) external returns (address, address, address, address, address);

}
