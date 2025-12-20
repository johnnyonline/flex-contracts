// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IPriceOracleScaled {
    function price() external view returns (uint256);
}
