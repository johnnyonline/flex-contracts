// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./Base.sol";

contract DaddyTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setup() public {
        assertEq(daddy.owner(), deployerAddress, "E0");
        assertEq(daddy.pending_owner(), address(0), "E1");
    }

    // ============================================================================================
    // Execute
    // ============================================================================================

    function test_execute() public {
        // Use execute to endorse a market on the registry
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);

        // Verify the call succeeded
        assertEq(registry.markets_count(), 1, "E0");
        assertEq(registry.markets(0), address(troveManager), "E1");
    }

    function test_execute_notOwner(
        address _notOwner
    ) public {
        vm.assume(_notOwner != deployerAddress);

        vm.expectRevert("!owner");
        vm.prank(_notOwner);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.endorse.selector, address(troveManager)), 0, true);
    }

    function test_execute_revertOnFailure() public {
        // Call something that will fail (unendorse without endorsing first)
        vm.expectRevert("call failed");
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.unendorse.selector, address(troveManager)), 0, true);
    }

    function test_execute_noRevertOnFailure() public {
        // Call something that will fail, but with revert_on_failure = false
        vm.prank(deployerAddress);
        daddy.execute(address(registry), abi.encodeWithSelector(IRegistry.unendorse.selector, address(troveManager)), 0, false);

        // Should not revert, market status unchanged
        assertEq(uint256(registry.market_status(address(troveManager))), uint256(IRegistry.Status.empty), "E0");
    }

    function test_execute_withEthValue() public {
        // Fund daddy contract with ETH
        vm.deal(address(daddy), 1 ether);

        // Execute a call that sends ETH
        address _recipient = address(0x0420);
        vm.prank(deployerAddress);
        daddy.execute(_recipient, "", 1 ether, true);

        assertEq(_recipient.balance, 1 ether, "E0");
        assertEq(address(daddy).balance, 0, "E1");
    }

    function test_receiveEther() public {
        vm.deal(deployerAddress, 1 ether);
        vm.prank(deployerAddress);
        (bool _success,) = address(daddy).call{value: 1 ether}("");
        assertTrue(_success, "E0");
        assertEq(address(daddy).balance, 1 ether, "E1");
    }

    // ============================================================================================
    // Ownership
    // ============================================================================================

    function test_transferOwnership(
        address _newOwner
    ) public {
        vm.assume(_newOwner != address(0));

        vm.prank(deployerAddress);
        daddy.transfer_ownership(_newOwner);

        assertEq(daddy.pending_owner(), _newOwner, "E0");
        assertEq(daddy.owner(), deployerAddress, "E1");
    }

    function test_transferOwnership_notOwner(
        address _notOwner
    ) public {
        vm.assume(_notOwner != deployerAddress);

        vm.expectRevert("!owner");
        vm.prank(_notOwner);
        daddy.transfer_ownership(address(1));
    }

    function test_acceptOwnership(
        address _newOwner
    ) public {
        vm.assume(_newOwner != address(0));

        vm.prank(deployerAddress);
        daddy.transfer_ownership(_newOwner);

        vm.prank(_newOwner);
        daddy.accept_ownership();

        assertEq(daddy.owner(), _newOwner, "E0");
        assertEq(daddy.pending_owner(), address(0), "E1");
    }

    function test_acceptOwnership_notPendingOwner(
        address _newOwner,
        address _notPendingOwner
    ) public {
        vm.assume(_newOwner != address(0));
        vm.assume(_notPendingOwner != _newOwner);

        vm.prank(deployerAddress);
        daddy.transfer_ownership(_newOwner);

        vm.expectRevert("!pending_owner");
        vm.prank(_notPendingOwner);
        daddy.accept_ownership();
    }

}
