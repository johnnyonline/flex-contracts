// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface ITroveManager {

    function BORROW_TOKEN() external view returns (address);
    function sync_total_debt() external returns (uint256);
    function redeem(
        uint256 amount,
        uint256 route_index
    ) external;

}
