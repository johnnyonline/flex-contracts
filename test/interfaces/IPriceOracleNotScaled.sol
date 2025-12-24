// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IPriceOracleNotScaled {

    function get_price(
        bool _scaled
    ) external view returns (uint256);

}
