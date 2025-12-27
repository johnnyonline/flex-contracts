// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IAuction {

    function is_ongoing_liquidation_auction() external view returns (bool);

}
