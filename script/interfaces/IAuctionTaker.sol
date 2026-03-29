// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IAuctionTaker {

    function takeAuction(
        address auction,
        uint256 auction_id
    ) external;

}
