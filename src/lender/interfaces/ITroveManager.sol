// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface ITroveManager {

    function sync_total_debt() external returns (uint256);
    function redeem(
        uint256 amount,
        address receiver
    ) external;

}
