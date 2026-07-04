// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IDeployer} from "./interfaces/IDeployer.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployLeverageZapperNG.s.sol:DeployLeverageZapperNG --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployLeverageZapperNG is Script {

    // Prod core
    address public constant DADDY = 0x4e8341C77c94cCE982AB96d92BB28D69f4638290;
    address public constant REGISTRY = 0x9117440a7D03238905d1C8908157Bd7a547c77c8;

    // CREATE2 deployer (CreateX) + salt
    bytes32 public constant SALT = bytes32(uint256(555));
    IDeployer public constant DEPLOYER = IDeployer(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    function run() public {
        uint256 _pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Derive deployer address from private key
        address _deployerAddress = vm.addr(_pk);

        require(_deployerAddress == address(0x000005281a2b04A182085D37cC9E6dD552795caa), "!johnny.flexmeow.eth");
        console2.log("Deployer address: %s", _deployerAddress);

        vm.startBroadcast(_pk);

        // Deploy a fresh swap executor (includes the unspent-input refund fix)
        address _swapExecutor = DEPLOYER.deployCreate2(keccak256(abi.encode(SALT, "swapExecutorNG")), abi.encodePacked(vm.getCode("swap_executor")));

        // Deploy the NG leverage zapper
        address _zapper = DEPLOYER.deployCreate2(
            keccak256(abi.encode(SALT, "leverageZapperNG")),
            abi.encodePacked(vm.getCode("leverage_zapper_ng"), abi.encode(DADDY, REGISTRY, _swapExecutor))
        );

        // Deploy the new swap-based auction taker
        address _auctionTaker = DEPLOYER.deployCreate2(
            keccak256(abi.encode(SALT, "swapAuctionTakerNG")), abi.encodePacked(vm.getCode("swap_auction_taker"), abi.encode(_swapExecutor))
        );

        console2.log("---------------------------------");
        console2.log("Swap Executor:      ", _swapExecutor);
        console2.log("Leverage Zapper NG: ", _zapper);
        console2.log("Swap Auction Taker: ", _auctionTaker);
        console2.log("---------------------------------");

        vm.stopBroadcast();
    }

}