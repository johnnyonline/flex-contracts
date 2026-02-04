// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract FactoryTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setup() public {
        // Immutables match original contracts from Deploy.s.sol
        assertEq(catFactory.TROVE_MANAGER(), originalTroveManager, "E0");
        assertEq(catFactory.SORTED_TROVES(), originalSortedTroves, "E1");
        assertEq(catFactory.DUTCH_DESK(), originalDutchDesk, "E2");
        assertEq(catFactory.AUCTION(), originalAuction, "E3");
        assertEq(catFactory.LENDER_FACTORY(), address(lenderFactory), "E4");

        // Default parameters match Base.sol variables
        assertEq(catFactory.MINIMUM_DEBT(), minimumDebt, "E5");
        assertEq(catFactory.MINIMUM_COLLATERAL_RATIO(), minimumCollateralRatio, "E6");
        assertEq(catFactory.UPFRONT_INTEREST_PERIOD(), upfrontInterestPeriod, "E7");
        assertEq(catFactory.INTEREST_RATE_ADJ_COOLDOWN(), interestRateAdjCooldown, "E8");
        assertEq(catFactory.LIQUIDATOR_FEE_PERCENTAGE(), liquidatorFeePercentage, "E9");
        assertEq(catFactory.MINIMUM_PRICE_BUFFER_PERCENTAGE(), minimumPriceBufferPercentage, "E10");
        assertEq(catFactory.STARTING_PRICE_BUFFER_PERCENTAGE(), startingPriceBufferPercentage, "E11");
        assertEq(catFactory.EMERGENCY_STARTING_PRICE_BUFFER_PERCENTAGE(), emergencyStartingPriceBufferPercentage, "E12");
        assertEq(catFactory.STEP_DURATION(), stepDuration, "E13");
        assertEq(catFactory.STEP_DECAY_RATE(), stepDecayRate, "E14");
        assertEq(catFactory.AUCTION_LENGTH(), auctionLength, "E15");

        // Version
        assertEq(catFactory.VERSION(), "1.0.0", "E16");
    }

}
