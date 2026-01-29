// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IKeeper {

    function report(
        address _strategy
    ) external returns (uint256, uint256);

}
