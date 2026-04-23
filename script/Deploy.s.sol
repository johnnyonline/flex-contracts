// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IAuctionTaker} from "./interfaces/IAuctionTaker.sol";
import {ICatFactory} from "./interfaces/ICatFactory.sol";
import {IDaddy} from "./interfaces/IDaddy.sol";
import {IDebtInFrontHelper} from "./interfaces/IDebtInFrontHelper.sol";
import {IDeployer} from "./interfaces/IDeployer.sol";
import {ILeverageZapper} from "./interfaces/ILeverageZapper.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {ISwapExecutor} from "./interfaces/ISwapExecutor.sol";

import {LenderFactory} from "../src/lender/LenderFactory.sol";
import {StrategyAprOracle} from "../src/lender/periphery/StrategyAprOracle.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// deploy:
// forge script script/Deploy.s.sol:Deploy --verify --slow -g 250 --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

// verify:
// vyper -f solc_json src/price_feed.vy > out/build-info/verify.json
// vyper -f solc_json --path lib/snekmate/src src/trove_manager.vy > out/build-info/verify.json

// constructor args:
// cast abi-encode "constructor(address)" 0xbACBBefda6fD1FbF5a2d6A79916F4B6124eD2D49

contract Deploy is Script {

    bool public isTest;
    bool public isLatestBlock;
    address public deployerAddress;

    // Original contracts
    address public originalAuction;
    address public originalDutchDesk;
    address public originalSortedTroves;
    address public originalTroveManager;

    // Factories
    ICatFactory public catFactory;
    LenderFactory public lenderFactory;

    // Periphery
    StrategyAprOracle public strategyAprOracle;
    IDebtInFrontHelper public debtInFrontHelper;
    ISwapExecutor public swapExecutor;
    ILeverageZapper public leverageZapper;
    IAuctionTaker public auctionTaker;

    // Daddy
    IDaddy public daddy;

    // Registry
    IRegistry public registry;

    // Tokens
    // IERC20 public borrowToken = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E); // crvUSD
    IERC20 public borrowToken = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    // IERC20 public collateralToken = IERC20(0x18084fbA666a33d37592fA2633fD49a74DD93a88); // tBTC
    // IERC20 public collateralToken = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599); // WBTC
    IERC20 public collateralToken = IERC20(0xAc37729B76db6438CE62042AE1270ee574CA7571); // yvWETH-2
    // IERC20 public collateralToken = IERC20(0xBF319dDC2Edc1Eb6FDf9910E39b37Be221C8805F); // yvcrvUSD-2

    // CREATE2 salt
    bytes32 public constant SALT = bytes32(uint256(0));

    // CREATE2 deployer
    IDeployer public DEPLOYER = IDeployer(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    function run() public {
        uint256 _pk = isTest ? 42_069 : vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Derive deployer address from private key
        deployerAddress = vm.addr(_pk);

        if (!isTest) {
            require(deployerAddress == address(0x000005281a2b04A182085D37cC9E6dD552795caa), "!johnny.flexmeow.eth");
            console.log("Deployer address: %s", deployerAddress);
        }

        vm.startBroadcast(_pk);

        // Deploy original contracts using CREATE2
        deployOriginalContracts();

        // Deploy daddy using CREATE2
        deployDaddy();

        // Deploy factories using CREATE2
        deployFactories();

        // Deploy registry using CREATE2
        deployRegistry();

        // Deploy periphery using CREATE2
        deployPeriphery();

        if (isTest) {
            vm.label({account: originalAuction, newLabel: "OriginalAuction"});
            vm.label({account: originalDutchDesk, newLabel: "OriginalDutchDesk"});
            vm.label({account: originalSortedTroves, newLabel: "OriginalSortedTroves"});
            vm.label({account: originalTroveManager, newLabel: "OriginalTroveManager"});
            vm.label({account: address(lenderFactory), newLabel: "LenderFactory"});
            vm.label({account: address(catFactory), newLabel: "CatFactory"});
            vm.label({account: address(daddy), newLabel: "Daddy"});
            vm.label({account: address(registry), newLabel: "Registry"});
            vm.label({account: address(strategyAprOracle), newLabel: "StrategyAprOracle"});
            vm.label({account: address(debtInFrontHelper), newLabel: "DebtInFrontHelper"});
            vm.label({account: address(swapExecutor), newLabel: "SwapExecutor"});
            vm.label({account: address(leverageZapper), newLabel: "LeverageZapper"});
            vm.label({account: address(auctionTaker), newLabel: "AuctionTaker"});
        } else {
            console2.log("---------------------------------");
            console2.log("Original Auction: ", originalAuction);
            console2.log("Original Dutch Desk: ", originalDutchDesk);
            console2.log("Original Sorted Troves: ", originalSortedTroves);
            console2.log("Original Trove Manager: ", originalTroveManager);
            console2.log("Lender Factory: ", address(lenderFactory));
            console2.log("Cat Factory: ", address(catFactory));
            console2.log("Daddy: ", address(daddy));
            console2.log("Registry: ", address(registry));
            console2.log("Strategy APR Oracle: ", address(strategyAprOracle));
            console2.log("Debt In Front Helper: ", address(debtInFrontHelper));
            console2.log("Swap Executor: ", address(swapExecutor));
            console2.log("Leverage Zapper: ", address(leverageZapper));
            console2.log("Auction Taker: ", address(auctionTaker));
            console2.log("---------------------------------");
        }

        vm.stopBroadcast();
    }

    function deployOriginalContracts() internal {
        originalAuction = DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "auction")), abi.encodePacked(vm.getCode("auction")));
        originalDutchDesk = DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "dutch_desk")), abi.encodePacked(vm.getCode("dutch_desk")));
        originalSortedTroves = DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "sorted_troves")), abi.encodePacked(vm.getCode("sorted_troves")));
        originalTroveManager = DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "trove_manager")), abi.encodePacked(vm.getCode("trove_manager")));
    }

    function deployFactories() internal {
        lenderFactory =
            LenderFactory(DEPLOYER.deployCreate2(SALT, abi.encodePacked(vm.getCode("LenderFactory.sol:LenderFactory"), abi.encode(address(daddy)))));
        require(lenderFactory.DADDY() == address(daddy), "DADDY mismatch");
        bytes memory catFactoryBytecode = abi.encodePacked(
            vm.getCode("factory"), abi.encode(originalTroveManager, originalSortedTroves, originalDutchDesk, originalAuction, address(lenderFactory))
        );
        catFactory = ICatFactory(DEPLOYER.deployCreate2(SALT, catFactoryBytecode));
        require(catFactory.LENDER_FACTORY() == address(lenderFactory), "LENDER_FACTORY mismatch");
    }

    function deployDaddy() internal {
        bytes memory daddyBytecode = abi.encodePacked(vm.getCode("daddy"), abi.encode(deployerAddress));
        daddy = IDaddy(DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "daddy")), daddyBytecode));
    }

    function deployRegistry() internal {
        bytes memory registryBytecode = abi.encodePacked(vm.getCode("registry"), abi.encode(address(daddy)));
        registry = IRegistry(DEPLOYER.deployCreate2(SALT, registryBytecode));
        require(registry.DADDY() == address(daddy), "daddy mismatch");
    }

    function deployPeriphery() internal {
        strategyAprOracle = StrategyAprOracle(
            DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "strategyAprOracle")), abi.encodePacked(type(StrategyAprOracle).creationCode))
        );
        debtInFrontHelper = IDebtInFrontHelper(
            DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "debtInFrontHelper")), abi.encodePacked(vm.getCode("debt_in_front_helper")))
        );
        swapExecutor =
            ISwapExecutor(DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "swapExecutor")), abi.encodePacked(vm.getCode("swap_executor"))));
        leverageZapper = ILeverageZapper(
            DEPLOYER.deployCreate2(
                keccak256(abi.encode(SALT, "leverageZapper")),
                abi.encodePacked(vm.getCode("leverage_zapper"), abi.encode(address(daddy), address(registry), address(swapExecutor)))
            )
        );
        auctionTaker =
            IAuctionTaker(DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "auctionTaker")), abi.encodePacked(vm.getCode("yv_auction_taker"))));
    }

}
