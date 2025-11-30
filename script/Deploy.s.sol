// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IDutchExchangeRoute} from "./interfaces/IDutchExchangeRoute.sol";
import {IExchangeHandler} from "./interfaces/IExchangeHandler.sol";
import {IExchangeRoute} from "./interfaces/IExchangeRoute.sol";
import {ILiquidationHandler} from "./interfaces/ILiquidationHandler.sol";
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
    ILiquidationHandler public liquidationHandler;
    IExchangeRoute public exchangeRoute;
    IDutchExchangeRoute public dutchExchangeRoute;
    IExchangeHandler public exchangeHandler;
    ISortedTroves public sortedTroves;
    ITroveManager public troveManager;

    ILender public lender;

    uint256 public minimumCollateralRatio = 110 * 1e16; // 110%
    uint256 public dustThreshold = 1e14; // 0.0001 tBTC
    uint256 public maxAuctionAmount = 20e18; // 20 tBTC
    uint256 public minAuctionAmount = 1e16; // 0.01 tBTC

    address public management = address(420_420);
    address public emergencyAdmin = address(69_420);
    address public performanceFeeRecipient = address(420_69_420);
    address public keeper = address(69_69);

    address public auctionFactory;

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
        address _lenderAddress = computeCreateAddress(deployer, _nonce + 7);
        address _troveManagerAddress = computeCreateAddress(deployer, _nonce + 6);

        priceOracle = IPriceOracle(deployCode("tbtc_yb_oracle"));
        liquidationHandler = ILiquidationHandler(
            deployCode(
                "liquidation_handler",
                abi.encode(
                    deployer,
                    _lenderAddress,
                    _troveManagerAddress,
                    address(priceOracle),
                    address(auctionFactory),
                    address(borrowToken),
                    address(collateralToken),
                    dustThreshold,
                    maxAuctionAmount
                )
            )
        );
        exchangeRoute = IExchangeRoute(deployCode("tbtc_yb_route"));
        exchangeHandler = IExchangeHandler(deployCode("exchange_handler", abi.encode(deployer, address(borrowToken), address(collateralToken))));
        dutchExchangeRoute = IDutchExchangeRoute(
            deployCode(
                "dutch_route",
                abi.encode(
                    deployer,
                    address(exchangeHandler),
                    address(priceOracle),
                    auctionFactory,
                    address(borrowToken),
                    address(collateralToken),
                    dustThreshold,
                    maxAuctionAmount,
                    minAuctionAmount
                )
            )
        );
        sortedTroves = ISortedTroves(deployCode("sorted_troves", abi.encode(_troveManagerAddress)));
        troveManager = ITroveManager(
            deployCode(
                "trove_manager",
                abi.encode(
                    _lenderAddress,
                    address(liquidationHandler),
                    address(exchangeHandler),
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

        // Set up the liquidation handler and transfer ownership to management
        setupLiquidationHandler();

        // Set up the dutch route and transfer ownership to management
        setupDutchRoute();

        if (isTest) {
            vm.label({account: address(priceOracle), newLabel: "PriceOracle"});
            vm.label({account: address(liquidationHandler), newLabel: "LiquidationHandler"});
            vm.label({account: address(exchangeRoute), newLabel: "ExchangeRoute"});
            vm.label({account: address(exchangeHandler), newLabel: "ExchangeHandler"});
            vm.label({account: address(sortedTroves), newLabel: "SortedTroves"});
            vm.label({account: address(troveManager), newLabel: "TroveManager"});
            vm.label({account: address(lender), newLabel: "Lender"});
        } else {
            console.log("---------------------------------");
            console.log("Price Oracle: ", address(priceOracle));
            console.log("Liquidation Handler: ", address(liquidationHandler));
            console.log("Exchange Route: ", address(exchangeRoute));
            console.log("Exchange Handler: ", address(exchangeHandler));
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
        exchangeHandler.add_route(address(exchangeRoute));
        exchangeHandler.add_route(address(dutchExchangeRoute));
        exchangeHandler.transfer_ownership(management);
    }

    function setupLiquidationHandler() public {
        liquidationHandler.set_keeper(keeper);
        liquidationHandler.transfer_ownership(management);
    }

    function setupDutchRoute() public {
        dutchExchangeRoute.set_keeper(keeper);
        dutchExchangeRoute.transfer_ownership(management);
    }

}
