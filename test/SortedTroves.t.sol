// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract SortedTrovesTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_sanity() public {
        assertTrue(address(sortedTroves) != address(0));
    }

}
