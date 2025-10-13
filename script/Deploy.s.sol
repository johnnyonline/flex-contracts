// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IExchange} from "./interfaces/IExchange.sol";
import {ISortedTroves} from "./interfaces/ISortedTroves.sol";
import {ITroveManager} from "./interfaces/ITroveManager.sol";

import {ILender} from "../src/lender/interfaces/ILender.sol";
import {Lender} from "../src/lender/Lender.sol";

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

    IExchange public exchange;
    ISortedTroves public sortedTroves;
    ITroveManager public troveManager;

    ILender public lender;

    uint256 public minimumCollateralRatio = 110 * 1e16; // 110%

    address public management = address(420_420);
    address public emergencyAdmin = address(69_420);
    address public performanceFeeRecipient = address(420_69_420);
    address public keeper = address(69_69);

    IERC20 public borrowToken = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E); // crvUSD
    IERC20 public collateralToken = IERC20(0x18084fbA666a33d37592fA2633fD49a74DD93a88); // tBTC

    function run() public {
        uint256 _pk = isTest ? 42_069 : vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Derive deployer address from private key
        deployer = vm.addr(_pk);

        if (!isTest) console.log("Deployer address: %s", deployer);

        vm.startBroadcast(_pk);

        uint256 _nonce = vm.getNonce(deployer);
        address _lenderAddress = computeCreateAddress(deployer, _nonce + 3);
        address _troveManagerAddress = computeCreateAddress(deployer, _nonce + 2);

        exchange = IExchange(deployCode("tbtc"));
        sortedTroves = ISortedTroves(deployCode("sorted_troves", abi.encode(_troveManagerAddress)));
        troveManager = ITroveManager(
            deployCode(
                "trove_manager",
                abi.encode(
                    _lenderAddress,
                    address(exchange),
                    address(sortedTroves),
                    address(borrowToken),
                    address(collateralToken),
                    minimumCollateralRatio
                )
            )
        );
        require(address(troveManager) == _troveManagerAddress, "!troveManagerAddress");

        lender = deployLender();
        require(address(lender) == _lenderAddress, "!lenderAddress");

        if (isTest) {
            vm.label({account: address(sortedTroves), newLabel: "SortedTroves"});
        } else {
            console.log("Deployer: ", deployer);
            console.log("Sorted Troves: ", address(sortedTroves));
        }

        vm.stopBroadcast();
    }

    function deployLender() public returns (ILender _lender) {
        _lender = ILender(address(new Lender(address(borrowToken), address(troveManager), "Lender Strategy")));
        _lender.setPerformanceFeeRecipient(performanceFeeRecipient);
        _lender.setKeeper(keeper);
        _lender.setPendingManagement(management);
        _lender.setEmergencyAdmin(emergencyAdmin);
    }
}
