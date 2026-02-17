// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract FactoryTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setup() public {
        // Cat Factory
        assertEq(catFactory.TROVE_MANAGER(), originalTroveManager, "E0");
        assertEq(catFactory.SORTED_TROVES(), originalSortedTroves, "E1");
        assertEq(catFactory.DUTCH_DESK(), originalDutchDesk, "E2");
        assertEq(catFactory.AUCTION(), originalAuction, "E3");
        assertEq(catFactory.LENDER_FACTORY(), address(lenderFactory), "E4");
        assertEq(catFactory.VERSION(), "1.0.0", "E5");

        // Lender Factory
        assertEq(lenderFactory.DADDY(), address(daddy), "E6");
    }

}
