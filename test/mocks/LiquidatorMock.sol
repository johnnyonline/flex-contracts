// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITroveManager} from "../interfaces/ITroveManager.sol";

import "forge-std/Test.sol";

contract LiquidatorMock is Test {

    ITroveManager public immutable troveManager;
    IERC20 public immutable borrowToken;

    constructor(
        ITroveManager _troveManager,
        IERC20 _borrowToken
    ) {
        troveManager = _troveManager;
        borrowToken = _borrowToken;
    }

    function liquidate(
        uint256 _troveId,
        uint256 _maxAmount
    ) external returns (uint256) {
        return troveManager.liquidate_trove(_troveId, _maxAmount, address(this), abi.encode(uint256(420)));
    }

    function takeCallback(
        uint256,
        address,
        uint256,
        uint256 _neededAmount,
        bytes calldata
    ) external {
        deal(address(borrowToken), address(this), _neededAmount);
        borrowToken.approve(msg.sender, _neededAmount);
    }

}
