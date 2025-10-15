// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";

interface ILender is IStrategy {

    function TROVE_MANAGER() external view returns (address);

}
