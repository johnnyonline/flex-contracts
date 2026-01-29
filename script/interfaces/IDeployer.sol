// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IDeployer {

    function deployCreate3(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address newContract);

    function deployCreate2(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address newContract);

}
