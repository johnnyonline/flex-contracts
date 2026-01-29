// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract PriceOracleTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_priceOracle() public {
        uint256 _price = priceOracle.get_price(false);
        console2.log("_price:", _price);
        assertGt(_price, 0);
    }

}
