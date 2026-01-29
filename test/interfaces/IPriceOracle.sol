// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IPriceOracle {

    function get_price(
        bool scaled
    ) external view returns (uint256);
    function get_price() external view returns (uint256);

}
