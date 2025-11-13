// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IExchange} from "./interfaces/IExchange.sol";
import {IExchangeRoute} from "./interfaces/IExchangeRoute.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ISortedTroves} from "./interfaces/ISortedTroves.sol";
import {ITroveManager} from "./interfaces/ITroveManager.sol";

import {Lender} from "../src/lender/Lender.sol";
import {ILender} from "../src/lender/interfaces/ILender.sol";

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

    IPriceOracle public priceOracle;
    IExchangeRoute public exchangeRoute;
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

        if (!isTest) {
            require(deployer == address(0x285E3b1E82f74A99D07D2aD25e159E75382bB43B), "!johnnyonline.eth");
            console.log("Deployer address: %s", deployer);
        }

        vm.startBroadcast(_pk);

        uint256 _nonce = vm.getNonce(deployer);
        address _lenderAddress = computeCreateAddress(deployer, _nonce + 5);
        address _troveManagerAddress = computeCreateAddress(deployer, _nonce + 4);

        priceOracle = IPriceOracle(deployCode("tbtc_yb_oracle"));
        exchangeRoute = IExchangeRoute(deployCode("tbtc_yb_route"));
        exchange = IExchange(deployCode("exchange", abi.encode(deployer, address(borrowToken), address(collateralToken))));
        sortedTroves = ISortedTroves(deployCode("sorted_troves", abi.encode(_troveManagerAddress)));
        troveManager = ITroveManager(
            deployCode(
                "trove_manager",
                abi.encode(
                    _lenderAddress,
                    address(exchange),
                    address(priceOracle),
                    address(sortedTroves),
                    address(borrowToken),
                    address(collateralToken),
                    minimumCollateralRatio
                )
            )
        );
        require(address(troveManager) == _troveManagerAddress, "!troveManagerAddress");

        lender = deployLender(isTest);
        require(address(lender) == _lenderAddress, "!lenderAddress");

        // Set up the exchange route and transfer ownership to management
        setupExchangeRoute();

        if (isTest) {
            vm.label({account: address(priceOracle), newLabel: "PriceOracle"});
            vm.label({account: address(exchangeRoute), newLabel: "ExchangeRoute"});
            vm.label({account: address(exchange), newLabel: "Exchange"});
            vm.label({account: address(sortedTroves), newLabel: "SortedTroves"});
            vm.label({account: address(troveManager), newLabel: "TroveManager"});
            vm.label({account: address(lender), newLabel: "Lender"});
        } else {
            console.log("---------------------------------");
            console.log("Price Oracle: ", address(priceOracle));
            console.log("Exchange Route: ", address(exchangeRoute));
            console.log("Exchange: ", address(exchange));
            console.log("Sorted Troves: ", address(sortedTroves));
            console.log("Trove Manager: ", address(troveManager));
            console.log("Lender: ", address(lender));
            console.log("---------------------------------");
        }

        vm.stopBroadcast();
    }

    function deployLender(
        bool _isTest
    ) public returns (ILender _lender) {
        _lender = ILender(address(new Lender(address(borrowToken), address(troveManager), "Lender Strategy")));
        if (_isTest) {
            _lender.setPerformanceFeeRecipient(performanceFeeRecipient);
            _lender.setKeeper(keeper);
            _lender.setPendingManagement(management);
            _lender.setEmergencyAdmin(emergencyAdmin);
        }
    }

    function setupExchangeRoute() public {
        exchange.add_route(address(exchangeRoute));
        exchange.transfer_ownership(management);
    }

}
