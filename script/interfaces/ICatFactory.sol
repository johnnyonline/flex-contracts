// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface ICatFactory {

    // ============================================================================================
    // Structs
    // ============================================================================================

    struct DeployParams {
        address borrow_token;
        address collateral_token;
        address price_oracle;
        address management;
        address performance_fee_recipient;
        uint256 minimum_debt;
        uint256 minimum_collateral_ratio;
        uint256 max_penalty_collateral_ratio;
        uint256 min_liquidation_fee;
        uint256 max_liquidation_fee;
        uint256 upfront_interest_period;
        uint256 interest_rate_adj_cooldown;
        uint256 minimum_price_buffer_percentage;
        uint256 starting_price_buffer_percentage;
        uint256 re_kick_starting_price_buffer_percentage;
        uint256 step_duration;
        uint256 step_decay_rate;
        uint256 auction_length;
        bytes32 salt;
    }

    // ============================================================================================
    // Constants
    // ============================================================================================

    // Contracts
    function TROVE_MANAGER() external view returns (address);
    function SORTED_TROVES() external view returns (address);
    function DUTCH_DESK() external view returns (address);
    function AUCTION() external view returns (address);
    function LENDER_FACTORY() external view returns (address);

    // Version
    function VERSION() external view returns (string memory);

    // ============================================================================================
    // Deploy
    // ============================================================================================

    function deploy(
        DeployParams calldata params
    ) external returns (address, address, address, address, address);

}
