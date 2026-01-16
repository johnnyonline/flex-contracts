// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/StdInvariant.sol";

import "../Base.sol";
import "./Handler.sol";

abstract contract BaseInvariant is StdInvariant, Base {

    Handler public handler;

    function setUp() public virtual override {
        Base.setUp();

        // Fund lender
        mintAndDepositIntoLender(userLender, maxFuzzAmount * 100);

        // Deploy handler
        handler = new Handler(
            troveManager,
            priceOracle,
            borrowToken,
            collateralToken,
            address(lender)
        );

        // Target handler
        targetContract(address(handler));
    }
}
