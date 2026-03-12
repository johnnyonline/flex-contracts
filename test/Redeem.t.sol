// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract RedeemTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_redeem_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != address(lender));

        vm.expectRevert("!lender");
        troveManager.redeem(0, address(0));
    }

}
