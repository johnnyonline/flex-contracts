// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IPriceOracle {

    function price(
        bool scaled
    ) external view returns (uint256);
    function price() external view returns (uint256);

}
