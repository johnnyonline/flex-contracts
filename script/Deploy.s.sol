// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ICatFactory} from "./interfaces/ICatFactory.sol";
import {IDeployer} from "./interfaces/IDeployer.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";

import {LenderFactory} from "../src/lender/LenderFactory.sol";

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
    address public deployerAddress;

    // Original contracts
    address public originalAuction;
    address public originalDutchDesk;
    address public originalSortedTroves;
    address public originalTroveManager;

    // Factories
    ICatFactory public catFactory;
    LenderFactory public lenderFactory;

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
    bytes32 public constant SALT = bytes32(uint256(420));

    // CREATE2 deployer
    IDeployer public DEPLOYER = IDeployer(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    function run() public {
        uint256 _pk = isTest ? 42_069 : vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Derive deployer address from private key
        deployerAddress = vm.addr(_pk);

        if (!isTest) {
            require(deployerAddress == address(0x285E3b1E82f74A99D07D2aD25e159E75382bB43B), "!johnnyonline.eth");
            console.log("Deployer address: %s", deployerAddress);
        }

        vm.startBroadcast(_pk);

        // Deploy original contracts using CREATE2
        deployOriginalContracts();

        // Deploy factories using CREATE2
        deployFactories();

        // Deploy registry using CREATE2
        deployRegistry();

        if (isTest) {
            vm.label({account: originalAuction, newLabel: "OriginalAuction"});
            vm.label({account: originalDutchDesk, newLabel: "OriginalDutchDesk"});
            vm.label({account: originalSortedTroves, newLabel: "OriginalSortedTroves"});
            vm.label({account: originalTroveManager, newLabel: "OriginalTroveManager"});
            vm.label({account: address(lenderFactory), newLabel: "LenderFactory"});
            vm.label({account: address(catFactory), newLabel: "CatFactory"});
            vm.label({account: address(registry), newLabel: "Registry"});
        } else {
            console2.log("---------------------------------");
            console2.log("Original Auction: ", originalAuction);
            console2.log("Original Dutch Desk: ", originalDutchDesk);
            console2.log("Original Sorted Troves: ", originalSortedTroves);
            console2.log("Original Trove Manager: ", originalTroveManager);
            console2.log("Lender Factory: ", address(lenderFactory));
            console2.log("Cat Factory: ", address(catFactory));
            console2.log("Registry: ", address(registry));
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
        lenderFactory = LenderFactory(DEPLOYER.deployCreate2(SALT, vm.getCode("LenderFactory.sol:LenderFactory")));
        bytes memory catFactoryBytecode = abi.encodePacked(
            vm.getCode("factory"), abi.encode(originalTroveManager, originalSortedTroves, originalDutchDesk, originalAuction, address(lenderFactory))
        );
        catFactory = ICatFactory(DEPLOYER.deployCreate2(SALT, catFactoryBytecode));
        require(catFactory.LENDER_FACTORY() == address(lenderFactory), "LENDER_FACTORY mismatch");
    }

    function deployRegistry() internal {
        bytes memory registryBytecode = abi.encodePacked(vm.getCode("registry"), abi.encode(deployerAddress));
        registry = IRegistry(DEPLOYER.deployCreate2(SALT, registryBytecode));
        require(registry.daddy() == deployerAddress, "daddy mismatch");
    }

}
