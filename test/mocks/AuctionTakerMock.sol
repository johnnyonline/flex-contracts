// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAuction} from "../interfaces/IAuction.sol";

import "forge-std/Test.sol";

contract AuctionTakerMock is Test {

    function takeAuction(
        address _auction,
        uint256 _auctionId
    ) external {
        address _buyToken = IAuction(_auction).buy_token();
        IAuction(_auction).take(_auctionId, type(uint256).max, address(this), abi.encode(_buyToken));
    }

    function takeCallback(
        uint256,
        address,
        uint256,
        uint256 _neededAmount,
        bytes calldata _data
    ) external {
        address _buyToken = abi.decode(_data, (address));
        deal(_buyToken, address(this), _neededAmount);
        IERC20(_buyToken).approve(msg.sender, _neededAmount);
    }

}
