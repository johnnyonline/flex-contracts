// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract AuctionPriceSimulationTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_printPriceAtEachStep() public view {
        uint256 startingPrice = 1000e18;
        uint256 price = startingPrice;
        uint256 multiplier = 10000 - stepDecayRate;

        console2.log("=== Price at Each Step ===");
        console2.log("Step Duration:", stepDuration);
        console2.log("Decay Rate:", stepDecayRate);
        console2.log("");

        for (uint256 step = 0; step <= 100; step++) {
            console2.log("Step %s: %s tokens", step, price / 1e18);

            if (step < 100) price = (price * multiplier) / 10000;
        }
    }

    function test_printTimeToReachMarketPrice() public view {
        // Market price (oracle price)
        uint256 marketPrice = 1000e18;

        // Starting price with buffer (e.g., 15% above market)
        uint256 auctionStartingPrice = (marketPrice * startingPriceBufferPercentage) / WAD;

        uint256 price = auctionStartingPrice;
        uint256 multiplier = 10000 - stepDecayRate;
        uint256 steps = 0;

        console2.log("");
        console2.log("=== Time to Reach Market Price ===");
        console2.log("Market Price: %s", marketPrice / 1e18);
        console2.log("Starting Price Buffer: %s%%", startingPriceBufferPercentage / 1e16);
        console2.log("Auction Starting Price: %s", auctionStartingPrice / 1e18);
        console2.log("Step Duration: %s seconds", stepDuration);
        console2.log("Step Decay Rate: %s basis points", stepDecayRate);
        console2.log("");

        while (price > marketPrice && steps < 10000) {
            price = (price * multiplier) / 10000;
            steps++;
        }

        uint256 timeInSeconds = steps * stepDuration;
        uint256 timeInMinutes = timeInSeconds / 60;

        console2.log("Steps to reach market price:", steps);
        console2.log("Time to reach market price in seconds:", timeInSeconds);
        console2.log("Time to reach market price in minutes:", timeInMinutes);
        console2.log("Final price:", price / 1e18, "tokens");
    }

}
