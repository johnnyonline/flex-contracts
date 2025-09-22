// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ISortedTroves} from "./interfaces/ISortedTroves.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// deploy:
// forge script script/Deploy.s.sol:Deploy --verify --slow --legacy --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

// verify:
// vyper -f solc_json src/price_feed.vy > out/build-info/verify.json
// vyper -f solc_json --path src/periphery --path src src/leverage_zapper.vy > out/build-info/verify.json

// constructor args:
// cast abi-encode "constructor(address)" 0xbACBBefda6fD1FbF5a2d6A79916F4B6124eD2D49

contract Deploy is Script {

    bool public isTest;
    address public deployer;

    ISortedTroves public sortedTroves;

    function run() public {
        uint256 _pk = isTest ? 42_069 : vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Derive deployer address from private key
        deployer = vm.addr(_pk);

        if (!isTest) console.log("Deployer address: %s", deployer);

        vm.startBroadcast(_pk);

        sortedTroves = ISortedTroves(deployCode("sorted_troves"));

        if (isTest) {
            vm.label({account: address(sortedTroves), newLabel: "SortedTroves"});
        } else {
            console.log("Deployer: ", deployer);
            console.log("Sorted Troves: ", address(sortedTroves));
        }

        vm.stopBroadcast();
    }

}
