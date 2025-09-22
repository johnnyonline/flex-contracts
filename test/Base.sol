// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import "../script/Deploy.s.sol";

import "forge-std/Test.sol";

abstract contract Base is Deploy, Test {

    address public user = address(420);

    function setUp() public virtual {
        // notify deplyment script that this is a test
        isTest = true;

        // create fork
        uint256 _blockNumber = 23_420_144; // cache state for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        // deploy and initialize contracts
        run();
    }

    function airdrop(address _token, address _to, uint256 _amount) public {
        _token == address(0) ? vm.deal(_to, _amount) : deal({token: _token, to: _to, give: _amount});
    }

}
